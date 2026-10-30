# Dev Writer運用状態と初回適用手順

Dev/Prod共通の通常手順は[Migration Writer運用手順](./migration-writer-handoff.md)を参照する。この文書はDev固有の準備状態と未検証項目を記録する。

## 現在の状態

- Dev Reader検証、DB identity marker、Dev Writer資格情報のread-only identity probeは成功済み
- `development-db-apply`はmain限定、Required reviewers 1名、administrator bypass無効。GitHub APIの読み取り専用確認済み
- Dev DB passwordはローテーション済みで、receipt-managerの旧ローカルWriter passwordは削除済み
- `DEV_DB_WRITER_ENABLED=false`
- Dev shared migration historyは`IN_SYNC`
- shared WriterによるDevのPENDING migration実適用は未検証。Devの`IN_SYNC` apply runがno-opで成功しても適用能力の検証にはならない

Environment secret/variableの値はこの文書やログに記録しない。Reader/Writerのread-only接続成功は、PENDING migrationの実適用を証明しない。

## DB identity marker

Writer workflowはPostgreSQL `postgres` databaseのcommentを読み、コードに固定したtarget/project refと一致することをReaderおよびWriter接続で確認する。Writer側の照合も`BEGIN TRANSACTION READ ONLY`内のcatalog queryで、migration適用直前に実行する。marker欠落・不一致・照会失敗は停止条件。

現在のDB markerと資格情報probeは確認済み。将来DB restore/cloneやproject切替があった場合は、管理者がDashboard上のProject Refを独立確認し、markerを確認・再設定して作業記録を残す。誤設定や特権管理者による変更までは暗号学的に防がないidentity attestationである。

## Dev Writer Environment

`development-db-check`はDev Reader専用。`development-db-apply`は次の保護を読み取り確認済み。

| 設定 | 確認状態 |
| --- | --- |
| Deployment branch policy | `main` branch 1件 |
| Required reviewers | 1名 |
| Administrator bypass | 無効 |
| `DEV_DB_WRITER_ENABLED` | `false` |
| Dev Writer credential | read-only authentication/identity probe成功 |

Dev passwordの現行値・接続変数の値は取得・記録しない。適用時もDev専用EnvironmentとDev専用資格情報だけを使用し、Prod設定と混在させない。

## Devの通常実行順

1. shared migration PRで新規timestamp SQL、checksum、隔離SQL検証、両アプリ互換性をレビューする。既存migrationは変更しない。
2. migrationがmainへ入った後、`.github/workflows/dev-migration-plan.yml`をmainから手動実行し、inventory/checksum、identity、Reader権限、履歴を確認する。`PENDING`表示は計画のみで適用しない。
3. `.github/workflows/dev-consumer-db-contract-check.yml`とshared apply preflightで、両アプリの現行契約が通ることを確認する。予定version・SQLとReader結果をレビューする。
4. 実適用に対する明示承認がある場合のみ、Dev Environmentの`DEV_DB_WRITER_ENABLED`を一時的に`true`へ変更し、`Apply Dev DB migrations`をmainからdispatchする。
5. Reader preflight成功とPENDING version一覧を再確認し、`development-db-apply` Environmentの承認画面でmigration・対象・SHAをレビュー後に承認する。workflowはWriter identityを再確認してから適用する。
6. Reader postflightのhistory `IN_SYNC`、Reader権限、両アプリ契約、Dev contract integrity PASSを確認する。成功後は`DEV_DB_WRITER_ENABLED=false`に戻す。
7. 新schemaを必要とするアプリ契約を更新し、アプリ側Reader gateとアプリテストを通した後にアプリを配信する。

ProdはDev結果を根拠に自動適用せず、独立したReader preflight、Prod承認、Prod flag、Prod Environment承認、Writer identity、Reader postflightを必要とする。Prod実適用には別途明示承認を必須とする。

## 失敗時の復旧

- Reader preflight/identity/history/contract failure、またはEnvironment承認拒否ではWriter適用へ進まない。flagはfalseのままにする。
- Writer認証・identity失敗では再適用せず、資格情報値を表示せずに管理者がtargetとcredential設定を確認する。
- Writer CLI失敗や結果不明では即時再実行しない。Reader postflightとDev migration planで適用済みversion、部分適用、契約、identityを読み取り確認する。
- migration SQLを編集・削除せず、自動rollbackもしない。必要な修復はレビュー済みforward migrationで行う。
- 旧receipt-manager `db:push`は停止済み。復旧のために旧ローカルWriter credentialや経路を戻さない。

Production Writerの準備・実適用に関する承認事項は[Migration Writer運用手順](./migration-writer-handoff.md)に従う。
