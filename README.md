# shared-supabase-db

共有Supabaseデータベースのmigration正本、Reader検証、承認付きWriter運用を管理するリポジトリ。Dev/Prodのhosted DB確認と適用は、main限定の専用GitHub Actions workflowを通じて行う。

## 前提

- `supabase/migrations/` はreceipt-managerから移した既存14本を保持
- 適用済みmigrationは不変。変更ではなく、新しいmigrationの追加で変更を表現
- Supabase CLIをローカルからhosted projectへ実行しない。migration適用はsharedの保護されたWriter workflowだけを使う
- PR CIは使い捨てPostgreSQLだけを使用し、Supabase認証情報を受け取らない
- hosted DB接続はDev/Prod別Environmentを使う手動workflowに限定する。Reader checksはread-only。Writer接続はmigration applyとAI quotaのパスワード設定workflowだけが行う
- shared `supabase/migrations/` と`SHA256SUMS`が共有DB全体のinventory/history正本。アプリ側migration一覧はDB全体の履歴判定に使わない

## 開発

必要環境: Node.js 22、Python 3.12、PostgreSQL 17と`psql`。

```sh
npm ci
npm run check
```

SQLテスト6系統は専用の新しいPostgreSQLクラスター上で実行する。ReaderテストはPostgreSQL 17コンテナを自動起動する。AI quotaテストはクラスター全体にロールを作るため、他のSQLテストともクラスターを分ける。

```sh
AI_QUOTA_TEST_ALLOW_DISPOSABLE_DB=YES \
AI_QUOTA_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:5432/ai_quota_test \
  npm run test:sql:ai-quota
PRICE_MEMO_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:5432/price_memo_data_deletion_test \
  npm run test:sql:data-deletion
PRICE_MEMO_BROADCAST_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:5432/price_memo_private_broadcast_test \
  npm run test:sql:private-broadcast
npm run test:sql:migration-reader
PRICE_FOLDER_READING_SCHEMA_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:5432/price_folder_reading_schema_test npm run test:sql:folder-reading-schema
DB_CONTRACT_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:5432/db_contract_test \
  npm run test:sql:contract
```

SQLテスト接続先はloopbackに限定され、テストごとの専用データベース名を要求する。AI quotaテストはfresh clusterを使う。テスト用URLをシェル履歴やログに残さないこと。

手動Reader・Writer workflowではランナー搭載の`psql`を接続前に検査し、PostgreSQL 17または18のクライアントのみを許可する。対象DBはPostgreSQL 17で、古い16以前や未検証の19以降、コマンド欠落・版数不明では接続前に停止する。`apt-get`への自動フォールバックは行わない。GitHub Actionsの`ubuntu-latest`は更新されるため、PR CIで実ランナーのクライアント検査と隔離PostgreSQL 17のSQLテストを実施する。

開発者向けOCRの日次制限・AIブレーカー例外の設計と管理は [運用手順](docs/ai-quota-developer-exception.md) を参照。

## Migration運用の入口

通常の変更手順、Reader preflight、Environment承認、Writer identity、Reader postflight、失敗時の復旧は[Migration Writer運用手順](docs/migration-writer-handoff.md)を参照する。hosted DBへの直接接続やローカル`supabase db push`は使わない。

| 用途 | 手動workflow | 読み取り/書き込み | 判定と制約 |
| --- | --- | --- | --- |
| Dev/Prod DB確認 | `db-check.yml`（`target`で選択） | 対象のReader only | inventory・identity・Reader権限・履歴・両アプリ契約を確認。`IN_SYNC`のときは対象のintegrityも確認。連続prefixの`PENDING`はversion表示だけで適用せず、integrityは省略 |
| Dev/Prod migration apply | `apply-dev-db-migrations.yml` / `apply-production-db-migrations.yml` | Reader preflight → 承認付きWriter → Reader postflight | `IN_SYNC`はno-op。連続prefixの`PENDING`のみ対象。適用にはEnvironment承認が必要 |
| アプリ本番deploy gate | receipt-manager / price-memo各`deploy.yml` | shared Production Reader | DB identity・shared history `IN_SYNC`・対象commitのアプリ契約を検証。適用しない |

DevとProdは独立して計画・承認・実行する。一方の履歴状態を他方へ流用しない。

## DB読み取り専用検証

`.github/workflows/db-check.yml`は`workflow_dispatch`専用で、mainからの実行だけを受け付ける。`target`（`dev` / `production`）に対応する`development-db-check` / `production-db-check` Environmentと、そのReader資格情報だけを使う。最新main SHA、migrationの不変性とchecksum、固定SHAの両アプリ契約の形式を確認してから接続し、DB identity、Readerの最小権限、Reader bootstrap、migration履歴、両アプリ契約を検査する。履歴が`IN_SYNC`のときは、ProdではRPC・AI quota・ACL、DevではAI quotaと管理roleのintegrityも検査する。`PENDING`は成功扱いでintegrityを省略し、job summaryに明記する。`REMOTE_ONLY`、`ERROR`、接続・診断・契約エラーは失敗扱い。`IN_SYNC`の確認が必要な場合はjob summaryの履歴結果を確認する。PR CIからはhosted DBへ接続せず、workflowはmigration適用や書き込みを行わない。

workflowはEnvironmentや資格情報を作成・変更しない。手動実行前にGitHub Settingsで対象のEnvironmentが存在し、Deployment branchesが`main`だけに制限され、以下の既存設定（Prodの場合）が正しいことを確認する。Devの設定名は[Dev DB契約検証の事前設定](docs/dev-db-contract-reader-bootstrap.md)を参照。

1. Environment Variables
   - `PROD_SUPABASE_POOLER_HOST`: ProdプロジェクトのConnect画面からコピーしたSession Poolerのhostのみ（URL・portなし）
   - `PROD_SUPABASE_PROJECT_REF`: 同じProdプロジェクトのproject ref
2. Environment Secret
   - `MIGRATION_READER_PASSWORD`: 既存`migration_preflight_login`専用のReaderパスワード
3. Hostとproject refの組み合わせ、Reader専用パスワードの所有者、Environmentのmain制限を確認
4. 承認後にActions画面から`main`を選んで手動実行

workflowはSession Poolerのhost形式と、Reader専用username、port `5432`、database `postgres`、SSL `require`、secretの存在を接続前に確認する。Supabaseの共有Session Poolerはport `5432`を使い、custom roleのusernameは`<role>.<project-ref>`形式。[Supabase接続ドキュメント](https://supabase.com/docs/guides/database/connecting-to-postgres)

Environment未設定、変数・secret欠落、main以外からのdispatch、最新main SHAとの不一致ではDB接続前に停止する。Writer用SecretやGitHub Settingsの変更はこのworkflowに含めない。

## Dev DB確認の事前設定

Dev Environment/LOGINの現状確認と、未整備時のbootstrap手順は[Dev DB契約検証の事前設定](docs/dev-db-contract-reader-bootstrap.md)を参照。EnvironmentやLOGINはworkflowから作成・変更しない。

## アプリDB互換性契約

契約形式v1、カタログ検証器、静的検査と実動作検査の境界、固定revisionの取得方式は[DB互換性契約の設計](docs/db-compatibility-contracts.md)を参照。検証器はPostgreSQLカタログのみをread-only transactionで照合する。`scripts/fixtures/db-contract-v1.example.json`は形式・テスト専用で、アプリの実契約ではない。

```sh
python3 scripts/check-db-contract.py scripts/fixtures/db-contract-v1.example.json --validate-only
python3 scripts/check-db-contract.py path/to/consumer-owned-contract.json
```

shared側から固定SHAの両契約を検証するには`.github/workflows/db-check.yml`をmainから手動実行する。このworkflowは公開GitHub API/raw URLから契約を取得し、DB接続前に両方の形式を検証してから既存Reader資格情報で照合する。PR CIや通常の`npm run check`はホストDBへ接続しない。

カタログ照合に業務テーブル行のSELECTは不要。成功表示はカタログ上の静的検査のみを意味し、RLS実動作・Authユーザー間分離・RPC結果・Realtime配信を保証しない。契約の判定とmigration履歴の判定は、同じworkflow内の別の結果として扱う。

## Migrationの不変性

`supabase/migrations/SHA256SUMS` は移植時の14本のSHA-256を記録する。`npm run check:migrations` はファイル名・順序・内容ハッシュを検証し、CIは保護ブランチとの差分で既存ファイルの編集・削除・改名を拒否する。

## 現在の状態と未完了作業

- Dev/Prod Reader検証とWriter資格情報のread-only identity probeは成功済み。Dev passwordはローテーション済みで旧ローカルWriter passwordは削除済み
- `development-db-apply`と`production-db-apply`はmain-only、Required reviewersあり、administrator bypass無効。これらのGitHub protection metadataは読み取り専用で確認済み
- Dev/Prodともshared Writerによる`PENDING` migrationの実適用とReader postflightは成功済み（2026-11-23）
- Prodへの実適用は毎回別途の明示承認、Environment reviewer承認、Reader postflightを必要とする
- receipt-managerの旧Production Writer Secretは、両アプリの互換性・本番配信成功と旧Writer参照経路の再監査を確認し、別途承認して削除する
