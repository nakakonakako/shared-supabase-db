# Dev Writer切り替え準備

## 現状と境界

現状は次の通り。Environment/Secretの値は読み取らず、GitHubの設定値を変更しない。

- `development-db-check`にはDev Reader用の接続変数と`DEV_MIGRATION_READER_PASSWORD`が設定済み
- `development-db-apply`はmain限定の保護設定で存在し、Dev Writer用変数と`DEV_MIGRATION_SUPABASE_DB_PASSWORD`が設定済み
- Dev Writer資格情報によるread-only接続・identity検証は成功済み
- `DEV_DB_WRITER_ENABLED=false`。Dev DB passwordは未ローテーション
- receipt-manager PR #39はマージ済み。`npm run db:push`は環境準備・パスワード要求・Supabase CLI実行前に停止

コード上の旧`db:push`停止とDB password失効は別対策。現行のDev passwordが有効な間は、ローカルに残った資格情報から直接Supabase CLIや他のPostgreSQLクライアントを使える可能性がある。Writer有効化の前にpasswordをローテーションし、旧値を失効させる。

`aws-1-ap-northeast-1.pooler.supabase.com`は現在Dev/Prodで共通するshared pooler hostであり、project identityには使えない。shared workflowに固定したproject refとSupavisor usernameの整合性検査は、接続要求の設定を検査するだけでサーバーのidentity証明ではない。Supabaseの接続仕様ではshared poolerのusernameにproject refを含めるが、これは接続先選択情報としてクライアントから送る値である。[Supabase接続仕様](https://supabase.com/docs/guides/database/connecting-to-postgres)、[Supavisor tenant routing](https://supabase.github.io/supavisor/connecting/overview/)。PostgreSQLの標準catalogにはSupabase project refを返す読取専用の識別列がない。

## DB側identity marker

Dev Writer workflowは`pg_catalog.shobj_description`で`postgres` databaseのcommentを読み、コード内で固定したtarget/refと完全一致することを要求する。marker欠落、不一致、問い合わせ失敗はfail-closed。ReaderとWriterの両接続で同じ確認をし、Writer接続ではmigration適用直前に再確認する。marker照合は`BEGIN TRANSACTION READ ONLY`内のcatalog queryだけで、業務テーブルのSELECT権限やReaderの追加GRANTを必要としない。PostgreSQL 17の使い捨て環境で、追加のDB権限がないLOGINからの読取を検証する。

初回有効化時は、Dev Supabase DashboardのProject Refを別途確認したDB管理者が、Devの`postgres` databaseへ次のcommentを設定する。これはdatabase metadataの書き込みであり、今回の作業では実行しない。migrationにも含めない。

```sql
COMMENT ON DATABASE postgres IS
  'shared-supabase-db:target=dev;project_ref=irgahixsuvtopiwmtkku';
```

誤ってProd markerをDevへ設定するとworkflowが拒否する。database clone/restore後もmarkerを再確認する。これは管理者が正しい値を設定する運用に依存するidentity attestationであり、特権管理者による誤設定・改変や、異なる環境間でcommentをコピーした場合まで暗号学的に防ぐものではない。Project Refを独立確認したDB管理者の作業記録を残す。

## GitHub Environmentの準備

`development-db-check`は既存Reader専用Environmentとして維持する。新たなReader権限や資格情報は追加しない。

`development-db-apply`は作成・保護済み。設定項目は次の通り。Secret値は取得していない。

| 種別 | 名前 | 設定 |
| --- | --- | --- |
| Deployment branches | Selected branches and tags | `main` branch 1件 |
| Protection | Administrator bypass | 無効 |
| Protection | Required reviewers | 1名、Prevent self-review無効 |
| Environment variable | `DEV_SUPABASE_POOLER_HOST` | Dev Session Pooler host |
| Environment variable | `DEV_SUPABASE_PROJECT_REF` | Dev Project Ref。コード固定値と一致 |
| Environment variable | `DEV_DB_WRITER_ENABLED` | `false` |
| Environment secret | `DEV_MIGRATION_SUPABASE_DB_PASSWORD` | Dev `postgres` role用password。未ローテーション |

Writer Environmentを作成してSecretを登録しただけではapplyは有効にならない。shared apply workflowは`DEV_DB_WRITER_ENABLED`が厳密に`true`でなければDevのWriter jobを失敗させる。Dev Writer接続確認workflowはフラグが`false`の間も実行でき、migration適用コマンドを持たない。protection metadata APIがEnvironment、main-only policy、Required reviewers、self-review設定を確認できない場合は接続前に停止する。

このrepositoryはGitHubアカウント1人で運用するため、DevではRequired reviewersを1名以上設定し、Prevent self-reviewを無効にする。起動者本人が自分のworkflowを承認できるが、これは独立した職務分離ではなく、誤操作を防ぐ手動確認ゲートである。`check-writer-environment.py`はreviewerとboolean設定の存在を検査し、Devでは`Prevent self-review=false`を要求する。main限定とadministrator bypass無効は維持する。

## 検証手順

順番を変えず、各段階の記録を確認する。

1. **完了:** Dev identity marker、Reader検証、Dev Writer資格情報のread-only identity probe
2. **完了:** `development-db-apply`のmain-only保護とWriter用Environment設定。`DEV_DB_WRITER_ENABLED=false`を維持
3. **完了:** receipt-manager PR #39で旧`npm run db:push`経路を停止
4. **Reader migration plan:** `.github/workflows/dev-migration-plan.yml`をmainから手動実行。shared inventory/checksum、Dev identity、Reader権限、migration履歴を検査し、`IN_SYNC`または予定version付き`PENDING`を表示する。このworkflowはWriter資格情報、Supabase CLI dry-run、DB契約検証を使わない。契約検証はDev consumer contract workflowで別途行う
5. Dev DB passwordをローテーションし、shared `development-db-apply` の`DEV_MIGRATION_SUPABASE_DB_PASSWORD`を新値へ更新。旧値を端末・パスワード保管先から削除
6. `DEV_DB_WRITER_ENABLED=false`のままWriter read-only identity probeを再実行。成功後も、明示的な切替承認まではfalseを維持
7. 実際のPENDING migrationを適用する段階でのみWriterを有効化し、Reader preflight、両アプリ契約、identity、適用、Reader postflightを確認

適用能力の実証は7の実際のDev migrationで行う。no-op用の不要なmigrationは追加しない。PR #9の隔離PostgreSQL 17 PENDING testはCLI/状態遷移の隔離検証であり、hosted DevへのWriter接続や適用の証拠ではない。

## 二重Writer防止と復旧

別repository間のGitHub Actions concurrencyは排他として扱わない。旧`db:push`停止に加えてDev DB passwordをローテーションし、端末に残る旧credentialを無効化する。共有Writerを有効化するまで`DEV_DB_WRITER_ENABLED=false`を保ち、切替中はmigration適用を凍結する。今回追加するReader migration planはDev DB履歴を確認する。ローカル開発は引き続き可能で、Dev側のmigration状態照会はshared workflowで行う。

- Reader identity/preflight失敗: Writerへ進まず、markerとDev Project Refを管理者が別途照合。Reader権限を増やさない
- Writer credential probe失敗: `DEV_DB_WRITER_ENABLED=false`のまま停止。Secret値をログに出さず、DB管理者がcredentialとmarkerを個別確認してからprobeを再実行
- apply失敗: 旧Writerへ切り替えて即時再適用しない。Readerでmigration履歴、identity、契約、部分適用状態を調べ、承認されたshared経路でforward recoveryする
- 旧経路への復旧が必要: 先にsharedフラグを`false`にし、実行中のshared Writerがないことを確認。旧経路を再導入する変更とcredential復元を明示的に承認してから行い、sharedを有効にしたまま旧Writerを戻さない

## この作業の境界

今回追加するworkflow/ガード/文書は準備のみ。hosted Dev/Prodへの接続、database comment設定、Writer password作成/rotation、GitHub Environment/Secretの作成・更新、migration適用は行わない。Dev Writer稼働には上記手動準備と承認済み切替作業が残る。
