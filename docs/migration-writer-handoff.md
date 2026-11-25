# Shared DB migration運用手順

## 責務と適用経路

共有Supabase DB全体のmigration inventory、SHA256SUMS、適用履歴の正本はshared-supabase-dbの`supabase/migrations/`。receipt-managerとprice-memoはアプリDB契約とアプリ開発を担当し、各repositoryのmigration一覧をDB全体履歴として判定しない。

| 経路 | 用途 | DB権限 | migration適用 |
| --- | --- | --- | --- |
| shared `dev-migration-plan.yml` | Devのinventory、identity、Reader権限、履歴確認 | Dev Reader | しない。`IN_SYNC`または連続prefixの`PENDING`を報告 |
| shared `production-migration-plan.yml` | Prodのinventory、identity、Reader権限、履歴確認 | Prod Reader | しない。`IN_SYNC`または連続prefixの`PENDING` versionを報告 |
| shared `apply-dev-db-migrations.yml` | Devへの承認済み適用 | Reader preflight、保護EnvironmentのWriter、Reader postflight | Environment承認後のPENDINGだけ |
| shared `apply-production-db-migrations.yml` | Prodへの承認済み適用 | Reader preflight、保護EnvironmentのWriter、Reader postflight | Environment承認後のPENDINGだけ |
| shared `production-db-check.yml` | Production Readerの権限・history・integrity確認 | Production Reader | しない。history `IN_SYNC`が必須 |
| receipt-manager / price-memo `deploy.yml` | アプリ配信前のDB gate | Production Reader | しない。shared history `IN_SYNC`とアプリ契約PASSが必須 |

`IN_SYNC`ではWriter workflowはCLIを呼ばず安全なno-opを行う。`PENDING`はshared migration履歴の連続prefixである場合に限りapply候補となる。`REMOTE_ONLY`、`ERROR`、接続・診断・契約エラーは停止する。PENDINGの適用には対象Environmentのreviewer承認が必要。アプリのpushやdeployはmigrationを自動適用しない。

両apply workflowは`workflow_dispatch`専用で、mainからのみ実行する。同じtargetのworkflowはshared repository内のconcurrencyで直列化する。PENDING時はReader preflight後にWriter Environmentの保護を検査し、apply jobがEnvironment承認を待つ。承認後にも最新main、target、history immutability、Writer identityを再確認する。apply後はReader接続でidentity、履歴`IN_SYNC`、Reader権限、両アプリ契約を検査し、ProdではRPC・AI quota・ACL integrityも検査する。

receipt-managerの旧Production apply/bootstrap workflowと本番Writer Secret参照はmainから撤去済み。price-memoにもhosted DB Writer経路はない。アプリ側に残る`db:push`停止stub、local migrations、隔離PostgreSQLテストはhosted DB適用経路ではない。旧receipt-manager Production Writer Secretは未削除のまま保管されている。shared Production Writerの初回PENDING適用、Reader postflight、両アプリの互換性確認と本番配信成功、旧Writer参照経路がないことの再監査が完了するまでは削除しない。その後も別途承認を得て削除する。

## Environment保護と現在の状態

`development-db-apply`と`production-db-apply`はGitHub APIの読み取り専用確認で、いずれもmainだけのbranch policy、Required reviewers 1名、administrator bypass無効を確認済み。Environment secrets/variablesの値は読み出していない。ReaderおよびWriter接続のread-only検証成功は、PENDING migrationの適用成功を意味しない。

接続値は対象ごとの専用Environmentにだけ登録する。Reader用は`development-db-check`の`DEV_SUPABASE_POOLER_HOST`、`DEV_SUPABASE_PROJECT_REF`、`DEV_MIGRATION_READER_PASSWORD`、および`production-db-check`の`PROD_SUPABASE_POOLER_HOST`、`PROD_SUPABASE_PROJECT_REF`、`MIGRATION_READER_PASSWORD`。Writer用は`development-db-apply`の`DEV_SUPABASE_POOLER_HOST`、`DEV_SUPABASE_PROJECT_REF`、`DEV_MIGRATION_SUPABASE_DB_PASSWORD`、および`production-db-apply`の`PROD_SUPABASE_POOLER_HOST`、`PROD_SUPABASE_PROJECT_REF`、`MIGRATION_SUPABASE_DB_PASSWORD`。値をworkflow log、CLI引数、文書へ出さない。

現在の運用状態：

- Dev/Prodともshared Writerによる`PENDING` migrationの実適用とReader postflightは成功済み（2026-11-23）
- Dev DB passwordはローテーション済みで、旧ローカルWriter passwordは削除済み
- Prodのmigration applyは毎回別途の明示承認が必要

## DB identity marker

Writer workflowはPostgreSQL `postgres` databaseのcommentを読み、コードに固定したtarget/project refと一致することをReaderおよびWriter接続で確認する。Writer側の照合も`BEGIN TRANSACTION READ ONLY`内のcatalog queryで、migration適用直前に実行する。marker欠落・不一致・照会失敗は停止条件。将来DB restore/cloneやproject切替があった場合は、管理者がDashboard上のProject Refを独立確認し、markerを確認・再設定して作業記録を残す。誤設定や特権管理者による変更までは暗号学的に防がないidentity attestationである。

## 通常のmigration変更・適用手順

### 1. Migration候補を準備する

1. schema変更のPRはshared-supabase-dbに作成する。既存migrationは編集・削除・改名せず、新しい14桁timestamp migrationとして追加する。
2. migration inventory、`SHA256SUMS`、両アプリとの互換性、必要なReader/Writer診断をレビューする。隔離PostgreSQLテストは専用の使い捨てDB/clusterだけで実行する。
3. migration PRをmainへ反映しても、hosted DBへは適用されない。アプリ側の新契約・機能を先行配信せず、現在main上の両アプリ契約が通るexpand変更から進める。

### 2. 対象環境のReader preflightを行う

1. mainの最新commitを対象に、Devは`dev-migration-plan.yml`と`dev-consumer-db-contract-check.yml`、Prodは`production-migration-plan.yml`と`consumer-db-contract-check.yml`を手動実行する。Prod historyがすでに`IN_SYNC`なら`production-db-check.yml`も実行できる。workflow runは同じcommit SHAで記録する。
2. migration planでDB identity、最小Reader権限、shared inventory/checksum、履歴を確認する。consumer contract checkで両アプリ契約を確認する。RPC/AI quota/ACL integrityは`production-db-check.yml`とapply後のpostflightで確認し、Writer identityは承認後のapply jobが適用前に照合する。履歴planはmigration一覧を提示するだけで、Writer applyではない。
3. apply候補がある場合はplan/checkerの`PENDING`一覧がshared migrationの連続prefixであることをレビューする。`REMOTE_ONLY`、`ERROR`、診断不一致、契約不一致、接続失敗は停止する。

### 3. Writer applyを手動実行・承認する

PENDINGを実適用する前に、変更対象とリスク、migration SQL、Reader preflight結果、復旧案をレビューする。承認はEnvironment reviewer承認の1回で、他に切り替える設定はない。

1. GitHub Actionsで対象の`Apply Dev DB migrations`または`Apply production DB migrations` workflowを選び、branch `main`からdispatchする。
2. Reader preflightが成功し、状態が`PENDING`で、表示されたversionとSQLが承認対象と一致することを確認する。Environment承認では適用内容・対象DB・最新run SHA・実行理由を確認してから承認する。
3. apply jobはmain SHA、target、Writer接続設定を再検証し、Writer credentialsによるDB identity markerをread-onlyで照合してからshared CLIで適用する。別のterminalやrepositoryから並行適用しない。
4. `IN_SYNC`ならno-opとなりWriter applyを要求しない。migrationの自動適用やアプリdeployへの連鎖はない。

### 4. Reader postflightとアプリ配信を確認する

1. apply workflowのReader postflightが成功し、historyが`IN_SYNC`、Reader権限、両アプリ契約、対象に応じたintegrityがすべてPASSであることを確認する。
2. 新schemaを使うアプリ契約をshared側で固定してから、各アプリのdeploy Reader gateが対象commitの契約PASSとshared history `IN_SYNC`を確認できることを確認する。その後アプリを個別に配信する。アプリdeploy workflowからmigrationは適用しない。
3. ProdはDevの適用・postflight・アプリ互換性確認後、Prod固有のReader preflightと別途の明示承認を経て同じ手順を繰り返す。Prod migration実適用は別途承認を必須とする。
4. receipt-managerの旧Production Writer Secretは、初回shared Production PENDING適用とReader postflightが成功し、両アプリのDB互換性と本番配信成功を確認した後に、receipt-managerおよびsharedの全workflowに旧Writer参照経路がないことを再監査する。その結果をレビューして別途承認を得た後でのみ削除する。初回実適用前は削除しない。

## 失敗時の停止と復旧

- **Reader preflight、Environment保護/承認、Writer認証/identity、CLI、postflightのいずれかが失敗、workflowがキャンセル、または結果不明:** Actions run/jobの状態を確認し、稼働中なら終了または明示的なcancelを確認する。承認待ちのrunは承認せずcancelする。
- **実行状態とDB状態の確認:** runが終了したことと残存jobがないことを確認し、Reader接続でidentity、migration履歴、適用済みversion、部分適用、両アプリ契約を調べる。failure/cancel/unknown直後に再dispatchしない。原因とDB状態を特定し、復旧方針と再実行について別途レビュー・承認を得る。
- **履歴・診断の異常:** `REMOTE_ONLY`、`ERROR`、部分適用、Reader postflight失敗ではアプリ配信を停止する。Reader権限を場当たり的に追加せず、適用済みmigrationを編集・削除せず、DBの自動rollbackもしない。運用者レビュー後に承認済みforward migrationまたは互換アプリ版で復旧する。
- **復旧経路:** 旧receipt-manager Writer経路はmainから撤去済みであり、復旧のためにアプリ側Writerを再有効化しない。shared applyを使う場合も、状態の確認とEnvironment承認を改めて行う。

適用済みSQLを戻す前提で運用しない。DB password rotation、旧Production Writer Secretの削除、Environment/Secret/Variableの変更はmigration適用とは別の承認・変更作業とする。
