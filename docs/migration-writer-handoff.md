# shared DB migration Writer workflow

## この実装段階の範囲

`apply-dev-db-migrations.yml` と `apply-production-db-migrations.yml` は、mainからの手動実行だけを受け付ける。両方とも同じ再利用workflowを呼び出すが、呼び出し側でtargetを固定し、Reader Environment、Writer Environment、接続先変数、資格情報を分離する。PR CIからhosted DBへの接続はない。

Dev Writer identity marker、Writer credentialのread-only probe、旧receipt-manager経路を閉じる切替条件と復旧順は[Dev Writer切り替え準備](./dev-writer-cutover.md)を参照する。Dev applyは`DEV_DB_WRITER_ENABLED=true`を明示設定するまでfail-closed。Productionも独立した`PROD_DB_WRITER_ENABLED=true`が設定されるまでPENDING migrationを適用しない。Production用のread-only資格情報probeはWriterが無効のまま実行できる。

DB接続前に、Environmentのproject refをworkflowコード内のDev/Prod固定project refと照合する。Environment変数同士の検証だけでは、Dev EnvironmentへProdの接続先一式を誤登録した場合を検出できないため、この独立pinで拒否する。Dev/Prodで共有するpooler hostnameは接続先識別子として扱わない。固定refの変更はプロジェクト切替を伴う明示的なコードレビュー対象とする。この事前検査はEnvironment設定ミスを防ぐが、接続後のSupabase側project identityを別制御面から証明するものではない。切替段階では接続後のidentity照合も必須とし、資格情報登録前にDev/Prodそれぞれの期待値を確認する。

この段階はWriter workflow基盤と隔離テストだけを追加する。GitHub EnvironmentやSecretを作成・変更せず、hosted DBへ接続せず、migrationも適用しない。workflowに参照されるEnvironmentが未作成または保護不足なら、Reader事前検証の後、GitHub APIの読み取り専用保護確認で停止する。未設定のEnvironmentをGitHubが暗黙に作成して適用jobへ進むことを避ける。

Writer Environmentはworkflowのmain制限に加えて、GitHub側で事前に作成し、`main`だけのdeployment branch policyとadministrator bypass無効を設定する。Devでは `development-db-apply` に `DEV_SUPABASE_POOLER_HOST`、`DEV_SUPABASE_PROJECT_REF`、`DEV_MIGRATION_SUPABASE_DB_PASSWORD` を設定する。Prodでは `production-db-apply` に `PROD_SUPABASE_POOLER_HOST`、`PROD_SUPABASE_PROJECT_REF`、`MIGRATION_SUPABASE_DB_PASSWORD` を設定し、`PROD_DB_WRITER_ENABLED=false`を初期値として登録する。値の登録は別途承認された切り替え作業で行い、このPRではEnvironment、Variables、Secretsを変更しない。

Prod EnvironmentにはRequired reviewersが最低1名必要。独立承認者を用意できない場合は、同一運用者をreviewerにした手動承認を設定できるが、これは独立した職務分離ではなく、実行を止めて確認した記録を残すゲートに限られる。可能なら別の管理者・運用者をreviewerにし、Prevent self-reviewとadministrator bypass無効を設定する。独立承認者がいない間に使える追加保護は、main限定、手動dispatch、main SHA再確認、migration不変性/checksum確認、Writer SecretのEnvironment限定、Reader事前/事後検証、同一shared repo内の直列化である。これらは独立承認の代替ではない。

Environment保護検査はdeployment branch policyの総数と全要素、`main`という名前、`branch`種別を確認する。API応答の欠落・不整合や未知のprotection ruleはfail-closedとする。

## 適用判定

適用workflowはsharedの `supabase/migrations/` と `SHA256SUMS` を履歴の唯一の基準として扱う。migration一覧の健全性とアプリ契約は別々に判定する。

Prodの`PENDING` applyは、apply job開始時と実適用helperの両方で`PROD_DB_WRITER_ENABLED`が厳密に`true`であることを要求する。未設定、`false`、大文字・別表記はfail-closedとなり、Writer CLIを実行しない。`IN_SYNC`は既存どおりWriter Environmentやenable flagを要求しない安全なno-op。Devの`DEV_DB_WRITER_ENABLED`判定と動作は独立して維持する。

`.github/workflows/verify-production-db-writer-connection.yml` は `workflow_dispatch` とmain refだけを許可するread-only probe。最初にProduction Readerでmigration history、Production identity marker、Reader/RPC/AI quota/ACLを確認し、次にGitHub APIから`production-db-apply`のmain-only policy、Required reviewers、administrator bypass無効を検証する。最後にprotected EnvironmentからWriter credentialを受け取り、target/credential形式を検査し、`verify-db-project-identity.py`の`BEGIN TRANSACTION READ ONLY`照合を実行する。probeにはSupabase CLI、apply helper、DB URL builderを含めず、enable flagがfalseのままWriter credentialを検証できる。

| 状態 | 判定 | Writer処理 |
| --- | --- | --- |
| `IN_SYNC` | DB履歴がsharedの全versionと一致 | Writer Environmentを要求せず、CLIを呼ばず、no-op後にReader postflight |
| `PENDING` | remote履歴がshared履歴の連続したprefixで、未適用versionだけが残る | 通常の適用対象。Writer Environment保護を確認し、承認後に再照合して適用 |
| `REMOTE_ONLY` | DBにsharedにないversionがある | 停止。自動修復・履歴の削除・適用をしない |
| `ERROR` | 接続/問い合わせ失敗、形式不正、local/remote履歴の分岐、checksum/不変性違反 | 停止。適用しない |

localに未適用versionがあってもremoteに後続versionがあるケースは、単純な `PENDING` としない。履歴の順序がsharedの連続prefixでなければ `ERROR` とする。Writer approval後にもmain SHA、migration不変性、履歴状態を再検査する。別workflow/repositoryのGitHub concurrencyが排他になるとは仮定しない。ProdのWriterを有効化する前に、receipt-managerの旧apply jobをmainから除去して旧Secret参照を不能にする。

適用には固定したSupabase CLIを使い、`supabase db push --yes --skip-vault` だけを呼ぶ。Vault secret同期、roles、seedのオプションを含めない。DB URLはrunnerの環境ファイルへpercent-encodeして渡し、URLやpasswordをログへ出さない。CLI出力は破棄し、失敗時は機密情報を含まない一般エラーを表示する。適用後はReaderによるhistory、Reader権限、契約、およびProdのintegrity検証がすべて成功しない限りworkflowを成功扱いしない。

## 契約とexpand/contract

適用前後の契約検証は、そのworkflow SHAに固定された `consumer_db_contracts.py` の両revisionを使う。同一workflowの途中で契約revisionを変えない。migrationの前後で現在稼働中の両アプリが引き続き動作できることを確認するための検証であり、migration履歴の `IN_SYNC` 判定とは別である。契約の形式検証はDB接続前に行う。

新しいアプリ契約がmigration前提のschemaを要求する場合、その契約SHAを先に更新してはならない。次の順で段階化する。

1. 現行両アプリの契約が通る後方互換なexpand migrationを追加し、shared Writerで適用
2. 新しい契約SHAをsharedへ固定し、Dev/Prod Readerで候補契約を検証
3. 両アプリのdeploy前Reader gateで同じ候補契約とshared migration履歴を検証してからアプリを配信
4. 全consumerが新しいschemaを使い、古いschemaに依存する実行中アプリがないことを確認後、contract migrationを別に適用

contract migration前には、現行アプリ契約が削除対象のschemaを要求していないことが必要。契約検証が不一致なら適用や配信を進めず、契約更新または互換schemaへのforward migrationをレビューする。

## Writer移管の段階

1. **receipt-manager Reader gateと旧Writer撤去（完了）:** PR #41はmainへmerge済み。shared migration履歴とreceipt-manager契約のReader gate、RPC/AI quota/ACL integrity gateがmainにあり、旧deploy apply、Reader bootstrap workflow、旧Writer secret参照はreceipt-manager workflowから撤去済み。
2. **price-memo Reader gate（完了）:** shared migration履歴とprice-memo契約を確認する固定SHA Reader gateを導入し、本番deploy成功を確認済み。アプリのDB Writer資格情報を使わない。
3. **Dev cutover:** shared `development-db-apply` を保護設定してから専用Secretを登録する。Devで旧receipt-managerのローカルWriter経路を使えない状態を確認してshared workflowから適用し、Reader postflightと両アプリ検証を通す。
4. **Prod Writer preparation:** receipt-manager PR #41がmainへmerge済みで旧deploy Writer経路は撤去済み。旧Writer Secretが残っていてもmainのworkflowから参照されないこと、他にmigration apply経路がないことを確認してから、shared `production-db-apply` をmain-only、Required reviewers必須、administrator bypass無効で準備し、variables/Secretを登録する。最初は`PROD_DB_WRITER_ENABLED=false`のままProduction Writer credential probeを手動実行する。Reader preflight、Environment保護、Writer credentialとidentity markerのread-only検証が成功してもapplyは有効にならない。
5. **Prod migration apply（別途明示承認が必要）:** 実際のProd migration適用はcredential probeとは別の作業。`PROD_DB_WRITER_ENABLED=true`への明示変更、保護Environmentの承認、およびProduction apply workflowの手動dispatchについて別途明示承認を得た後に限る。初回適用ではWriter再照合、適用、Reader postflightの全記録を確認する。

旧Writer Secretの削除とDB password rotationは別作業にする。旧workflowの無効化後も、旧SecretはsharedのWriter経路が成功するまで復旧用として保持できるが、旧workflowを再有効化する前にはshared Secretを無効化し、同時に適用可能な経路を作らない。shared workflowからの実適用とアプリ配信成功後に旧Secret参照がないことを棚卸しして削除する。DB password rotationは、shared側の新Secret登録・接続確認とDB側のcredential変更を管理者が同期して行える保守枠で別途実施し、失敗時の管理者break-glass経路を事前確認する。

## 失敗時

- Readerの接続、権限、履歴、契約検証が失敗した場合はWriterへ進まない。Reader権限を増やして通さない。
- Writer再照合が `IN_SYNC` になった場合は安全なno-op。`REMOTE_ONLY`、`ERROR`、非連続pendingは適用しない。
- CLI失敗後はmigrationを再実行せず、まずReaderでmigration履歴・catalog・両契約を確認する。適用済みmigrationは編集せず、修復はforward migrationとして扱う。
- CLIが失敗した場合もReader postflightを試み、部分適用や履歴状態をread-onlyで確認する。workflow自体はapply jobの失敗により成功扱いにならない。
- postflight失敗時はアプリdeployを止め、schemaを自動rollbackしない。Reader診断と運用者確認後、承認済みのforward repairまたはアプリ互換版で復旧する。
