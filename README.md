# shared-supabase-db

共有Supabaseデータベースのmigration正本と検証ツールを管理するリポジトリ。第1段階では正本と隔離検証を整備し、Supabaseプロジェクトへの管理操作は行わない。

## 前提

- `supabase/migrations/` はreceipt-managerから移した既存14本を保持
- 適用済みmigrationは不変。変更ではなく、新しいmigrationの追加で変更を表現
- Supabase CLIはローカル開発用。`db push`やlinked projectへの接続は使用しない
- PR CIは使い捨てPostgreSQLだけを使用し、Supabase認証情報を受け取らない
- 本番接続は`production-db-check` Environmentを使う手動・読み取り専用workflowに限定

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

## Dev/Prodのmigration履歴照合

照合は各環境の承認済み読み取り専用接続情報を使い、実行担当者が個別に行う。CIには接続情報を設定しない。migration適用やWriter権限はこの手順に含めない。

1. 対象環境の管理手順に従って読み取り専用のDB接続情報をシェル環境に設定する（`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGSSLMODE`, `PGPASSWORD`）。値をコマンド引数やログに出さない。
2. `psql -X -w -A -t -v ON_ERROR_STOP=1 -c 'SELECT version FROM supabase_migrations.schema_migrations ORDER BY version;'` で履歴を取得する。
3. 出力をアクセス制限された一時ファイルに保存し、`python3 scripts/check-migration-history.py --remote-versions-file <一時ファイル>` を実行する。照合後に一時ファイルを削除する。
4. `IN_SYNC`以外（`PENDING`、`REMOTE_ONLY`、接続失敗、形式エラー）は作業を止め、原因を調査する。両環境の結果を環境名・日時・commit SHAとともに変更記録へ残す。

DevとProdは個別に照合し、両方の結果をレビューする。migration履歴照合はスキーマや権限の健全性検証を代替せず、DB更新を実行しない。

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

## 次段階への移行前に必要な設定

- GitHubのmainブランチ保護とこのCIの必須チェック設定
- receipt-managerとprice-memoのmigration参照先・開発手順をshared-supabase-dbへ切り替える変更計画（各リポジトリで別途レビュー）
- Dev/Prodの読み取り専用履歴照合に使う担当者向け接続方法とアクセス承認
- 将来Writerを導入する場合の別途設計・承認。現段階ではworkflow、Environment、Secretsを設定しない
