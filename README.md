# shared-supabase-db

共有Supabaseデータベースのmigration正本と検証ツールを管理するリポジトリ。第1段階では正本と隔離検証を整備し、Supabaseプロジェクトへの管理操作は行わない。

## 前提

- `supabase/migrations/` はreceipt-managerから移した既存14本を保持
- 適用済みmigrationは不変。変更ではなく、新しいmigrationの追加で変更を表現
- Supabase CLIはローカル開発用。`db push`やlinked projectへの接続は使用しない
- CIは使い捨てPostgreSQLでSQL検証を行う

## 開発

必要環境: Node.js 22、Python 3.12、PostgreSQL 17と`psql`。

```sh
npm ci
npm run check
```

SQLテスト3系統は専用の新しいPostgreSQLクラスター上で実行する。AI quotaテストはクラスター全体にロールを作るため、他のSQLテストともクラスターを分ける。

```sh
AI_QUOTA_TEST_ALLOW_DISPOSABLE_DB=YES \
AI_QUOTA_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:5432/ai_quota_test \
  npm run test:sql:ai-quota
PRICE_MEMO_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:5432/price_memo_data_deletion_test \
  npm run test:sql:data-deletion
PRICE_MEMO_BROADCAST_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:5432/price_memo_private_broadcast_test \
  npm run test:sql:private-broadcast
```

URLはloopbackに限定され、テストごとの専用データベース名を要求する。テスト用URLをシェル履歴やログに残さないこと。

## Dev/Prodのmigration履歴照合

照合は各環境の承認済み読み取り専用接続情報を使い、実行担当者が個別に行う。CIには接続情報を設定しない。migration適用やWriter権限はこの手順に含めない。

1. 対象環境の管理手順に従って読み取り専用のDB接続情報をシェル環境に設定する（`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGSSLMODE`, `PGPASSWORD`）。値をコマンド引数やログに出さない。
2. `psql -X -w -A -t -v ON_ERROR_STOP=1 -c 'SELECT version FROM supabase_migrations.schema_migrations ORDER BY version;'` で履歴を取得する。
3. 出力をアクセス制限された一時ファイルに保存し、`python3 scripts/check-migration-history.py --remote-versions-file <一時ファイル>` を実行する。照合後に一時ファイルを削除する。
4. `IN_SYNC`以外（`PENDING`、`REMOTE_ONLY`、接続失敗、形式エラー）は作業を止め、原因を調査する。両環境の結果を環境名・日時・commit SHAとともに変更記録へ残す。

DevとProdは個別に照合し、両方の結果をレビューする。migration履歴照合はスキーマや権限の健全性検証を代替せず、DB更新を実行しない。

## Migrationの不変性

`supabase/migrations/SHA256SUMS` は移植時の14本のSHA-256を記録する。`npm run check:migrations` はファイル名・順序・内容ハッシュを検証し、CIは保護ブランチとの差分で既存ファイルの編集・削除・改名を拒否する。

## 次段階への移行前に必要な設定

- GitHubのmainブランチ保護とこのCIの必須チェック設定
- receipt-managerとprice-memoのmigration参照先・開発手順をshared-supabase-dbへ切り替える変更計画（各リポジトリで別途レビュー）
- Dev/Prodの読み取り専用履歴照合に使う担当者向け接続方法とアクセス承認
- 将来Writerを導入する場合の別途設計・承認。現段階ではworkflow、Environment、Secretsを設定しない
