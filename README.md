# shared-supabase-db

共有Supabaseデータベースのmigration正本、Reader検証、承認付きWriter運用を管理するリポジトリ。Dev/Prodのhosted DB確認と適用は、main限定の専用GitHub Actions workflowを通じて行う。

## 前提

- `supabase/migrations/` はreceipt-managerから移した既存14本を保持
- 適用済みmigrationは不変。変更ではなく、新しいmigrationの追加で変更を表現
- Supabase CLIをローカルからhosted projectへ実行しない。migration適用はsharedの保護されたWriter workflowだけを使う
- PR CIは使い捨てPostgreSQLだけを使用し、Supabase認証情報を受け取らない
- hosted DB接続はDev/Prod別Environmentを使う手動workflowに限定する。Reader checksとWriter identity probesはread-only、migration applyだけがWriter接続を行う
- shared `supabase/migrations/` と`SHA256SUMS`が共有DB全体のinventory/history正本。アプリ側migration一覧はDB全体の履歴判定に使わない

## 開発

必要環境: Node.js 22、Python 3.12、PostgreSQL 17と`psql`。

```sh
npm ci
npm run check
```

SQLテスト5系統は専用の新しいPostgreSQLクラスター上で実行する。ReaderテストはPostgreSQL 17コンテナを自動起動する。AI quotaテストはクラスター全体にロールを作るため、他のSQLテストともクラスターを分ける。

```sh
AI_QUOTA_TEST_ALLOW_DISPOSABLE_DB=YES \
AI_QUOTA_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:5432/ai_quota_test \
  npm run test:sql:ai-quota
PRICE_MEMO_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:5432/price_memo_data_deletion_test \
  npm run test:sql:data-deletion
PRICE_MEMO_BROADCAST_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:5432/price_memo_private_broadcast_test \
  npm run test:sql:private-broadcast
npm run test:sql:migration-reader
DB_CONTRACT_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:5432/db_contract_test \
  npm run test:sql:contract
```

SQLテスト接続先はloopbackに限定され、テストごとの専用データベース名を要求する。AI quotaテストはfresh clusterを使う。テスト用URLをシェル履歴やログに残さないこと。

## Migration運用の入口

通常の変更手順、Reader preflight、Writer enablement、Environment承認、Writer identity、Reader postflight、失敗時の復旧は[Migration Writer運用手順](docs/migration-writer-handoff.md)を参照する。hosted DBへの直接接続やローカル`supabase db push`は使わない。

| 用途 | 手動workflow | 読み取り/書き込み | 判定と制約 |
| --- | --- | --- | --- |
| Dev migration計画 | `dev-migration-plan.yml` | Dev Reader only | shared inventory・identity・Reader権限・履歴を確認。連続prefixの`PENDING`は計画表示だけで適用しない |
| Dev/Prod Writer資格情報確認 | `verify-dev-db-writer-connection.yml` / `verify-production-db-writer-connection.yml` | Reader preflight後にWriter identityをread-only照合 | Environment保護を確認。migration適用なし。Writer flagはfalseのまま実行可能 |
| Dev/Prod migration apply | `apply-dev-db-migrations.yml` / `apply-production-db-migrations.yml` | Reader preflight → 承認付きWriter → Reader postflight | `IN_SYNC`はno-op。連続prefixの`PENDING`のみ対象。Dev/Prod各enable flagが厳密に`true`の場合だけ適用 |
| Production DB check | `production-db-check.yml` | Production Reader only | history `IN_SYNC`、Reader/ACL/RPC/AI quota integrityを確認 |
| アプリ本番deploy gate | receipt-manager / price-memo各`deploy.yml` | shared Production Reader | DB identity・shared history `IN_SYNC`・対象commitのアプリ契約を検証。適用しない |

DevとProdは独立して計画・承認・実行する。一方の履歴状態を他方へ流用しない。

## 本番DB読み取り専用検証ゲート

`.github/workflows/production-db-check.yml`は`workflow_dispatch`専用で、mainからの実行だけを受け付ける。実行時にdispatch refと最新main SHAを確認し、履歴が`IN_SYNC`であること、Readerの最小権限、Reader bootstrap、RPC、AI quota、ACLの整合性を読み取り専用SQLで検査する。接続・履歴・診断エラーはすべて失敗扱い。PR CIからは本番へ接続せず、workflowはmigration適用や書き込みを行わない。

workflowはEnvironmentや資格情報を作成・変更しない。手動実行前にGitHub Settingsで`production-db-check`が存在し、Deployment branchesが`main`だけに制限され、以下の既存設定が正しいことを確認する。

1. Environment Variables
   - `PROD_SUPABASE_POOLER_HOST`: ProdプロジェクトのConnect画面からコピーしたSession Poolerのhostのみ（URL・portなし）
   - `PROD_SUPABASE_PROJECT_REF`: 同じProdプロジェクトのproject ref
2. Environment Secret
   - `MIGRATION_READER_PASSWORD`: 既存`migration_preflight_login`専用のReaderパスワード
3. Hostとproject refの組み合わせ、Reader専用パスワードの所有者、Environmentのmain制限を確認
4. 承認後にActions画面から`main`を選んで手動実行

workflowはSession Poolerのhost形式と、Reader専用username、port `5432`、database `postgres`、SSL `require`、secretの存在を接続前に確認する。Supabaseの共有Session Poolerはport `5432`を使い、custom roleのusernameは`<role>.<project-ref>`形式。[Supabase接続ドキュメント](https://supabase.com/docs/guides/database/connecting-to-postgres)

Environment未設定、変数・secret欠落、main以外からのdispatch、最新main SHAとの不一致ではDB接続前に停止する。Writer用SecretやGitHub Settingsの変更はこのworkflowに含めない。

## Dev DB契約検証ゲート

`.github/workflows/dev-consumer-db-contract-check.yml`はDev専用の手動・読み取り専用workflow。両アプリの固定SHA契約をDB接続前に検証し、Dev専用Readerでcatalogを照合する。Dev Environment/LOGINの現状確認と、未整備時のbootstrap手順は[Dev DB契約検証の事前設定](docs/dev-db-contract-reader-bootstrap.md)を参照。EnvironmentやLOGINはworkflowから作成・変更しない。

## アプリDB互換性契約

契約形式v1、カタログ検証器、静的検査と実動作検査の境界、固定revisionの取得方式は[DB互換性契約の設計](docs/db-compatibility-contracts.md)を参照。検証器はPostgreSQLカタログのみをread-only transactionで照合する。`scripts/fixtures/db-contract-v1.example.json`は形式・テスト専用で、アプリの実契約ではない。

```sh
python3 scripts/check-db-contract.py scripts/fixtures/db-contract-v1.example.json --validate-only
python3 scripts/check-db-contract.py path/to/consumer-owned-contract.json
```

shared側から固定SHAの両契約を検証するには`.github/workflows/consumer-db-contract-check.yml`をmainから手動実行する。このworkflowは公開GitHub API/raw URLから契約を取得し、DB接続前に両方の形式を検証してから既存Reader資格情報で照合する。PR CIや通常の`npm run check`はホストDBへ接続しない。

カタログ照合に業務テーブル行のSELECTは不要。成功表示はカタログ上の静的検査のみを意味し、RLS実動作・Authユーザー間分離・RPC結果・Realtime配信を保証しない。migration履歴の一致確認は既存の本番Reader workflowで独立して行う。

## Migrationの不変性

`supabase/migrations/SHA256SUMS` は移植時の14本のSHA-256を記録する。`npm run check:migrations` はファイル名・順序・内容ハッシュを検証し、CIは保護ブランチとの差分で既存ファイルの編集・削除・改名を拒否する。

## 現在の状態と未完了作業

- Dev/Prod Reader検証とWriter資格情報のread-only identity probeは成功済み。Dev passwordはローテーション済みで旧ローカルWriter passwordは削除済み
- `DEV_DB_WRITER_ENABLED=false`、`PROD_DB_WRITER_ENABLED=false`。Dev migration historyは`IN_SYNC`
- `development-db-apply`と`production-db-apply`はmain-only、Required reviewersあり、administrator bypass無効。これらのGitHub protection metadataは読み取り専用で確認済み
- Dev/Prodのshared WriterによるPENDING migration実適用は未検証。Devの`IN_SYNC` workflow成功はno-opであり、適用能力の証拠にはならない
- Prodへの実適用は別途の明示承認が必要。初回Dev/Prod applyも対象ごとの明示承認、enable flag切替、Environment reviewer承認、Reader postflightを必要とする
- receipt-managerの旧Production Writer Secretは初回shared Production PENDING適用、Reader postflight、両アプリの互換性・本番配信成功、旧Writer参照経路の再監査後に別途承認して削除する。初回実適用前は削除しない
