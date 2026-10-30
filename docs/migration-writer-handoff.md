# Shared DB migration運用手順

## 責務と適用経路

共有Supabase DB全体のmigration inventory、SHA256SUMS、適用履歴の正本はshared-supabase-dbの`supabase/migrations/`。receipt-managerとprice-memoはアプリDB契約とアプリ開発を担当し、各repositoryのmigration一覧をDB全体履歴として判定しない。

| 経路 | 用途 | DB権限 | migration適用 |
| --- | --- | --- | --- |
| shared `dev-migration-plan.yml` | Devのinventory、identity、Reader権限、履歴確認 | Dev Reader | しない。`IN_SYNC`または連続prefixの`PENDING`を報告 |
| shared `verify-dev-db-writer-connection.yml` | Dev Writer資格情報・identity probe | Reader preflight後にWriter接続をread-only照合 | しない |
| shared `verify-production-db-writer-connection.yml` | Prod Writer資格情報・identity probe | Reader preflight後にWriter接続をread-only照合 | しない |
| shared `apply-dev-db-migrations.yml` | Devへの承認済み適用 | Reader preflight、保護EnvironmentのWriter、Reader postflight | Dev flagが`true`のPENDINGだけ |
| shared `apply-production-db-migrations.yml` | Prodへの承認済み適用 | Reader preflight、保護EnvironmentのWriter、Reader postflight | Prod flagが`true`のPENDINGだけ |
| shared `production-db-check.yml` | Production Readerの権限・history・integrity確認 | Production Reader | しない。history `IN_SYNC`が必須 |
| receipt-manager / price-memo `deploy.yml` | アプリ配信前のDB gate | Production Reader | しない。shared history `IN_SYNC`とアプリ契約PASSが必須 |

`IN_SYNC`ではWriter workflowはCLIを呼ばず安全なno-opを行う。`PENDING`はshared migration履歴の連続prefixである場合に限りapply候補となる。`REMOTE_ONLY`、`ERROR`、接続・診断・契約エラーは停止する。Prodでは`PROD_DB_WRITER_ENABLED`、Devでは`DEV_DB_WRITER_ENABLED`が厳密に`true`でなければPENDINGを適用しない。アプリのpushやdeployはmigrationを自動適用しない。

両apply workflowは`workflow_dispatch`専用で、mainからのみ実行する。同じtargetのworkflowはshared repository内のconcurrencyで直列化する。PENDING時はReader preflight後にWriter Environmentの保護を検査し、apply jobがEnvironment承認を待つ。承認後にも最新main、target、history immutability、Writer identityを再確認する。apply後はReader接続でidentity、履歴`IN_SYNC`、Reader権限、両アプリ契約を検査し、ProdではRPC・AI quota・ACL integrityも検査する。

receipt-managerの旧Production apply/bootstrap workflowと本番Writer Secret参照はmainから撤去済み。price-memoにもhosted DB Writer経路はない。アプリ側に残る`db:push`停止stub、local migrations、隔離PostgreSQLテストはhosted DB適用経路ではない。旧receipt-manager Production Writer Secretは未削除のまま保管されているため、workflowへの再参照や旧経路の復旧を行わない。

## Environment保護と現在の状態

`development-db-apply`と`production-db-apply`はGitHub APIの読み取り専用確認で、いずれもmainだけのbranch policy、Required reviewers 1名、administrator bypass無効を確認済み。Environment secrets/variablesの値は読み出していない。ReaderおよびWriter接続のread-only検証成功は、PENDING migrationの適用成功を意味しない。

接続値は対象ごとの専用Environmentにだけ登録する。Reader用は`development-db-check`の`DEV_SUPABASE_POOLER_HOST`、`DEV_SUPABASE_PROJECT_REF`、`DEV_MIGRATION_READER_PASSWORD`、および`production-db-check`の`PROD_SUPABASE_POOLER_HOST`、`PROD_SUPABASE_PROJECT_REF`、`MIGRATION_READER_PASSWORD`。Writer用は`development-db-apply`の`DEV_SUPABASE_POOLER_HOST`、`DEV_SUPABASE_PROJECT_REF`、`DEV_MIGRATION_SUPABASE_DB_PASSWORD`、`DEV_DB_WRITER_ENABLED=false`、および`production-db-apply`の`PROD_SUPABASE_POOLER_HOST`、`PROD_SUPABASE_PROJECT_REF`、`MIGRATION_SUPABASE_DB_PASSWORD`、`PROD_DB_WRITER_ENABLED=false`。値をworkflow log、CLI引数、文書へ出さない。

現在の運用状態（2026-10-31時点の確認済み情報）：

- Dev/Prod Reader検証とDev/Prod Writer資格情報のread-only identity probeは成功済み
- Dev DB passwordはローテーション済みで、旧ローカルWriter passwordは削除済み
- `DEV_DB_WRITER_ENABLED=false`、`PROD_DB_WRITER_ENABLED=false`
- Dev migration historyは`IN_SYNC`
- Dev/Prodのshared WriterによるPENDING migration実適用は未検証。Devの`IN_SYNC` runはno-opであり、適用能力の証拠にはならない
- Prodのmigration applyは別途明示承認が必要。enable flagをfalseのまま維持する

## 通常のmigration変更・適用手順

### 1. Migration候補を準備する

1. schema変更のPRはshared-supabase-dbに作成する。既存migrationは編集・削除・改名せず、新しい14桁timestamp migrationとして追加する。
2. migration inventory、`SHA256SUMS`、両アプリとの互換性、必要なReader/Writer診断をレビューする。隔離PostgreSQLテストは専用の使い捨てDB/clusterだけで実行する。
3. migration PRをmainへ反映しても、hosted DBへは適用されない。アプリ側の新契約・機能を先行配信せず、現在main上の両アプリ契約が通るexpand変更から進める。

### 2. 対象環境のReader preflightを行う

1. mainの最新commitを対象に、Devは`dev-migration-plan.yml`と`dev-consumer-db-contract-check.yml`、Prodは`verify-production-db-writer-connection.yml`と`consumer-db-contract-check.yml`を手動実行する。Prod historyがすでに`IN_SYNC`なら`production-db-check.yml`も実行できる。workflow runは同じcommit SHAで記録する。
2. それぞれのworkflowが担うDB identity marker、最小Reader権限、Reader bootstrap、shared inventory/checksum、両アプリ契約、RPC/AI quota/ACL integrityの結果を確認する。履歴planはmigration一覧を提示するだけで、Writer applyではない。
3. apply候補がある場合はplan/checkerの`PENDING`一覧がshared migrationの連続prefixであることをレビューする。`REMOTE_ONLY`、`ERROR`、診断不一致、契約不一致、接続失敗は停止し、flagを変更しない。
4. Prod Writer credential probeはWriter flagがfalseでも実行できるread-only検査であり、apply承認の代替ではない。

### 3. Writerを対象環境だけで一時有効化する

PENDINGを実適用する場合にだけ、変更対象とリスク、migration SQL、Reader preflight結果、復旧案をレビューし、その環境の適用について明示承認を得る。対象Environment variableを`DEV_DB_WRITER_ENABLED=true`または`PROD_DB_WRITER_ENABLED=true`へ一時変更する。他方のflagは変更しない。flagをtrueにしてもworkflowは自動起動せず、mainからの手動dispatchとEnvironment reviewer承認が必要。

### 4. Writer applyを手動実行・承認する

1. GitHub Actionsで対象の`Apply Dev DB migrations`または`Apply production DB migrations` workflowを選び、branch `main`からdispatchする。
2. Reader preflightが成功し、状態が`PENDING`で、表示されたversionとSQLが承認対象と一致することを確認する。Environment承認では適用内容・対象DB・最新run SHA・実行理由を確認してから承認する。
3. apply jobはflag、main SHA、target、Writer接続設定を再検証し、Writer credentialsによるDB identity markerをread-onlyで照合してからshared CLIで適用する。別のterminalやrepositoryから並行適用しない。
4. `IN_SYNC`ならno-opとなりWriter applyを要求しない。`PENDING`でenable flagがfalse/未設定/不正値ならfail-closedで停止する。migrationの自動適用やアプリdeployへの連鎖はない。

### 5. Reader postflightとアプリ配信を確認する

1. apply workflowのReader postflightが成功し、historyが`IN_SYNC`、Reader権限、両アプリ契約、対象に応じたintegrityがすべてPASSであることを確認する。
2. 成功後は対象のWriter enable flagを`false`へ戻し、設定変更記録を残す。
3. 新schemaを使うアプリ契約をshared側で固定してから、各アプリのdeploy Reader gateが対象commitの契約PASSとshared history `IN_SYNC`を確認できることを確認する。その後アプリを個別に配信する。アプリdeploy workflowからmigrationは適用しない。
4. ProdはDevの適用・postflight・アプリ互換性確認後、Prod固有のReader preflightと別途の明示承認を経て同じ手順を繰り返す。Prod migration実適用は別途承認を必須とする。

## 失敗時の停止と復旧

- **Reader preflight、identity、history、integrity、契約の失敗:** Writerへ進まず停止する。flagをfalseのままにし、Reader権限を場当たり的に追加しない。原因を該当検証で調査する。
- **Environment保護不足、承認拒否、flag不正、Writer認証/identity失敗:** applyを開始しない。flagをfalseに保ち、Environment policyや資格情報を別途レビューしてからprobe/preflightをやり直す。credentialやtokenをログへ貼らない。
- **Writer CLIが失敗または結果不明:** 自動再実行や旧Writerへの切替をしない。workflowのReader postflightとDev migration plan/Prod Reader history checkで適用済みversion、部分適用、DB identity、両アプリ契約を読み取り確認し、flagをfalseへ戻す。適用済みmigrationを編集・削除せず、DBの自動rollbackをしない。
- **Reader postflight失敗:** アプリ配信を停止し、flagをfalseに戻す。Readerで状態と必要な診断を調べ、運用者レビュー後に承認済みforward migrationまたは互換アプリ版で復旧する。
- **復旧経路:** 旧receipt-manager Writer経路はmainから撤去済みであり、復旧のためにアプリ側Writerを再有効化しない。shared applyを使う場合も、状態の確認、対象flagの一時有効化、Environment承認を改めて行う。

適用済みSQLを戻す前提で運用しない。DB password rotation、旧Production Writer Secretの削除、Environment/Secret/Variableの変更はmigration適用とは別の承認・変更作業とする。
