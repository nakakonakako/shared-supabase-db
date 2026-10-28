# Dev Writer切り替え準備

## 現状と境界

2026-10-29にGitHubの公開設定メタデータで確認した範囲では、shared repositoryに`development-db-check`は存在し、Dev Reader用の変数`DEV_SUPABASE_POOLER_HOST`、`DEV_SUPABASE_PROJECT_REF`とSecret名`DEV_MIGRATION_READER_PASSWORD`が登録済み。値とSecret本文は読み取っていない。`development-db-apply`は未作成。receipt-managerには`production-db-check`のみがあり、Dev向けGitHub Environmentはない。

receipt-managerの`npm run db:push`はローカル端末からDevへ接続するWriter経路。`scripts/db-push.sh`は接続先をDev refに限定し、migration listとdry-runを表示し、TTYで`apply`を要求してからlinked projectへ適用する。sharedへ切り替えた後もこのコマンドが使えると二重Writer経路が残る。切替完了後のreceipt-manager専用PRで、linked Devへの適用部分を拒否またはplan-onlyにする。`db:plan`、ローカルSupabase開発、dry-runの利便性は維持する。旧経路を閉じるPRはshared Writerの安全な準備完了まで作らない。

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

`development-db-apply`は切替準備時に作成し、次を設定する。

| 種別 | 名前 | 設定 |
| --- | --- | --- |
| Deployment branches | Selected branches and tags | `main` branch 1件のみ |
| Protection | Administrator bypass | 無効 |
| Protection | Required reviewers | 1名以上、Prevent self-review無効 |
| Environment variable | `DEV_SUPABASE_POOLER_HOST` | Dev Session Pooler host |
| Environment variable | `DEV_SUPABASE_PROJECT_REF` | Dev Project Ref。コード固定値と一致させる |
| Environment variable | `DEV_DB_WRITER_ENABLED` | 初期値`false`。旧Writerを閉じた後だけ`true` |
| Environment secret | `DEV_MIGRATION_SUPABASE_DB_PASSWORD` | Dev `postgres` role用password |

Writer Environmentを作成してSecretを登録しただけではapplyは有効にならない。shared apply workflowは`DEV_DB_WRITER_ENABLED`が厳密に`true`でなければDevのWriter jobを失敗させる。Dev Writer接続確認workflowはフラグが`false`の間も実行でき、migration適用コマンドを持たない。protection metadata APIがEnvironment、main-only policy、Required reviewers、self-review設定を確認できない場合は接続前に停止する。

このrepositoryはGitHubアカウント1人で運用するため、DevではRequired reviewersを1名以上設定し、Prevent self-reviewを無効にする。起動者本人が自分のworkflowを承認できるが、これは独立した職務分離ではなく、誤操作を防ぐ手動確認ゲートである。`check-writer-environment.py`はreviewerとboolean設定の存在を検査し、Devでは`Prevent self-review=false`を要求する。main限定とadministrator bypass無効は維持する。

## 検証手順

順番を変えず、各段階の記録を確認する。

1. DB管理者が別のDashboardセッションでDev Project Refを照合し、Dev identity markerを設定
2. 既存の`development-db-check` Reader設定が揃い、sharedのDev contract checkが成功することを確認
3. `development-db-apply`をmain-only、bypass無効、reviewer必須/Prevent self-review無効で作成し、Writer variable/Secretを登録。`DEV_DB_WRITER_ENABLED=false`を維持
4. `Verify Dev DB Writer credentials (read-only)`をmainから手動実行。先にReader最小権限とReader identityを検査し、その後Protected Writer Environment承認を要求し、Writer credentialによるidentity queryだけを実行
5. `IN_SYNC`のshared apply runはReader preflight/postflightを検証する安全なno-op。Writer jobはskipされるため、Writer credential接続成功の証拠にしない
6. 旧receipt-manager `db:push` hosted apply経路を専用PRで閉じ、必要なDev password rotationを完了。旧passwordで接続できないことを管理者が安全に確認
7. Writer identity probeを新passwordで再実行。成功後にのみ`DEV_DB_WRITER_ENABLED=true`へ変更
8. 承認済みの実際のPENDING migrationがある場合に限り、shared Dev workflowを手動実行。Reader preflight、identity、履歴、両アプリ契約、Environment承認、Writer identity、適用、Reader postflightを確認

適用能力の実証は8の実際のDev migrationで行う。no-op用の不要なmigrationは追加しない。PR #9の隔離PostgreSQL 17 PENDING testはCLI/状態遷移の隔離検証であり、hosted DevへのWriter接続や適用の証拠ではない。

## 二重Writer防止と復旧

別repository間のGitHub Actions concurrencyは排他として扱わない。旧`db:push`を閉じ、必要ならDev DB passwordをrotateして端末に残る旧credentialを無効化し、sharedの環境フラグが`false`であることを確認してから共有applyを有効化する。切替中はmigration適用を凍結する。共有Writer有効化後は、receipt-managerのローカルコマンドからDevへ適用できない状態を保つ。ローカル開発と`db:plan`のdry-runは残す。

- Reader identity/preflight失敗: Writerへ進まず、markerとDev Project Refを管理者が別途照合。Reader権限を増やさない
- Writer credential probe失敗: `DEV_DB_WRITER_ENABLED=false`のまま停止。Secret値をログに出さず、DB管理者がcredentialとmarkerを個別確認してからprobeを再実行
- apply失敗: 旧Writerへ切り替えて即時再適用しない。Readerでmigration履歴、identity、契約、部分適用状態を調べ、承認されたshared経路でforward recoveryする
- 旧経路への復旧が必要: 先にsharedフラグを`false`にし、実行中のshared Writerがないことを確認。旧経路を再導入する変更とcredential復元を明示的に承認してから行い、sharedを有効にしたまま旧Writerを戻さない

## この作業の境界

今回追加するworkflow/ガード/文書は準備のみ。hosted Dev/Prodへの接続、database comment設定、Writer password作成/rotation、GitHub Environment/Secretの作成・更新、migration適用は行わない。Dev Writer稼働には上記手動準備と承認済み切替作業が残る。
