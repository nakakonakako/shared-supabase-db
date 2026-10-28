# Dev DB契約検証の事前設定

`.github/workflows/dev-consumer-db-contract-check.yml`は既存migrationが作る`migration_preflight_reader`グループと、専用LOGINを使う。WorkflowやPR CIはReader LOGIN、Environment設定、Secretを作成・変更しない。Devへの接続やDB変更も行わない。このEnvironmentは手動実行前に人が作成・設定する。未設定の変数やSecretは接続前の検証で拒否される。

## GitHub Environment

手動実行を有効にする前に、GitHub Settingsで`development-db-check` Environmentを作成し、Deployment branchesをSelected branches and tagsにして`main`だけを許可する。以下のDev専用設定を登録する。

| 種別 | 名前 | 値 |
|---|---|---|
| Environment Variable | `DEV_SUPABASE_POOLER_HOST` | Dev SupabaseのSession Pooler hostnameのみ。scheme、port、database pathを含めない |
| Environment Variable | `DEV_SUPABASE_PROJECT_REF` | 同じDev Supabase project ref |
| Environment Secret | `DEV_MIGRATION_READER_PASSWORD` | Devプロジェクトの`migration_preflight_login`専用パスワード |

Environmentと値は人が別途確認して設定する。このworkflowはProd変数・Secretへfallbackせず、Dev接続変数とPG接続値の不一致、Prod名の変数/Secretの混入、欠落値を接続前に拒否する。手動実行前にhostとproject refをDev Supabase Dashboardで照合し、Prodのhost/refを誤って登録していないことを確認する。Secret値は表示・ログ出力しない。

## Reader LOGIN

Reader migrationは非LOGINの`migration_preflight_reader`を作り、`supabase_migrations.schema_migrations.version`と`ai_quota.settings.id`のみをSELECT可能にする。業務テーブルのSELECT、Writer role所属、DDL権限は付与しない。契約検証はカタログ情報をread-only transactionで照合し、これらの業務データ権限を必要としない。

DevのReader LOGINが既にあるかは、ホストDBに接続しないと確定できない。承認済みのDev管理手順に従い、まずread-onlyで`pg_catalog.pg_roles`と`pg_catalog.pg_auth_members`の対象ロールだけを確認する。LOGINが未整備の場合は、Dev専用の強いランダムパスワードを別途発行し、権限を確認した担当者がDevに対してのみ次のbootstrapを行う。**このSQLは今回のPRでは実行していない。**

```sql
CREATE ROLE migration_preflight_login
  LOGIN
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  NOREPLICATION
  NOBYPASSRLS
  INHERIT;
GRANT migration_preflight_reader TO migration_preflight_login
  WITH INHERIT TRUE, SET FALSE;
ALTER ROLE migration_preflight_login
  SET default_transaction_read_only = on;
```

LOGIN作成後、承認済みのsecure `psql` sessionで`\password migration_preflight_login`を使ってパスワードを設定する。SQL本文、shell history、workflow logへパスワードを渡さない。既存LOGINがある場合は再作成や権限拡大をせず、role attribute、membership option、read-only既定値を確認する。

接続許可前に、Dev接続で`supabase/diagnostics/verify_migration_preflight_reader.sql`を実行し、migration readerの最小権限、LOGINの非特権属性、`default_transaction_read_only=on`、public業務テーブルのSELECT権限がないことを確認する。検証は承認済みのReader接続のみで行い、Writer権限を加えない。

## 手動実行

PR CIは使い捨てPostgreSQLだけを使用し、Dev/Prodに接続しない。PRがmainへマージされた後、EnvironmentとDev Reader LOGINの準備が完了したことを別途レビューし、Actions画面で`main`を選択してworkflowを手動実行する。実行前にGitHub Environmentのmain制限、Dev host/ref、Dev専用Secretの所有者、Dev/Prod project refの相違を再確認する。

Workflowは両アプリの契約を固定commit SHAから取得し、DB接続前に形式を検証する。catalog照合は契約ごとにread-only transactionで行い、migration履歴照合やmigration適用は行わない。
