# AI quota 開発者例外の管理

この仕組みは `developer_user_id` の設定・解除専用。各操作は手動起動し、対象の既存 `development-db-apply` / `production-db-apply` Environment の承認を通る。migration apply workflow と資格情報は別であり、Writer enable flag は使わない。main の最新コミット、Environment の承認と main 限定、接続先 project ref、DB 内 identity marker を照合し、不一致なら停止する。例外は OCR の日次 user/global 上限と未知利用ブレーカーを除外し、緊急停止・同時実行・月次計測費用上限は維持する。対象ユーザーの OCR は日次集計にも含まれない。

## 前提と権限

- この PR のマージは hosted DB を変更しないが、新 migration が未適用の間、shared inventory の `IN_SYNC` を必要とするアプリ配信 gate は停止する。Dev と本番の migration plan を別々に確認し、各環境の適用は別途明示承認する。Writer flag の有効化と復帰、適用、Reader postflight は既存の protected workflow に従う。
- migration は `ai_quota_admin_login` と NOLOGIN owner、固定関数、監査表を作る。ログインには関数実行権限だけを与え、設定表・監査表や Auth 表の直接権限は与えない。owner の設定表権限は必要な列に限る。Auth 妥当性のため postgres 所有の固定 `SECURITY DEFINER` 関数が限定照会する。一般 API ロールと backend に公開しない。
- 新ログインのパスワードは migration で設定しない。適用後、各Environmentに専用Secret `DEV_AI_QUOTA_ADMIN_PASSWORD` / `PROD_AI_QUOTA_ADMIN_PASSWORD` を別途承認して登録し、`Provision AI quota admin password` をmainから手動実行する。英数字・ピリオド・アンダースコア・ハイフンのみ32〜128文字のランダム値を使う。入力・コマンド引数・ログに値を置かない。既存Writer Secretは専用bootstrap workflow内でのみ使用し、専用ログインには付与しない。
- Environment の main 限定・必須レビュー・管理者バイパス無効を維持する。設定を変えず読み取り専用で確認する。workflow は保護が欠けると停止する。承認前に実行概要の target、operation、期待する現在値と新しい値の指紋を確認する。入力UUIDは Actions の実行入力に残るため、閲覧権限を制限する。
- 対象 UUID は小文字の標準形式で、該当DBの確認済み・ログイン済み・非匿名・未削除・停止されていない Auth ユーザーである必要がある。メール等はログに出さない。承認者は対象アカウントを別の信頼できる経路で確認する。UUID のSHA-256は秘密化ではない。

## Dev 検証から本番への手順

1. Dev migration plan、別途承認された migration 適用・Reader postflight を実施し、専用資格情報を別途承認して設定する。migration の事前条件や適用成否は hosted 環境で未検証である。失敗時は中止し調査する。
2. main から `Dev AI quota integrity (Reader only)` を手動実行する。Dev Reader とDB marker・migration履歴・quota/管理権限を読み取り専用で確認する。既存の破壊的な隔離SQLテストは hosted DB では実行しない。このチェックは設定値や実際のOCR動作を確認しない。
3. `Manage AI quota developer exception` を Dev の `preview` で実行し、承認後の現在値の指紋を記録する。`set` に対象UUIDと preview 指紋を指定し、提案内容を確認して承認する。更新は行ロック・事前値照合・アカウント確認・更新後確認・監査記録を同一トランザクションで行う。別途 `preview` で結果を照合し、実際のOCR動作をDevで確認する。解除は最新の preview 指紋を指定して `clear` を承認する。
4. Dev の結果をレビュー後、本番の migration plan、別途承認された適用・Reader postflight、専用資格情報設定を実施する。対象本番アカウントと指紋を独立に確認し、本番の `preview`、`set`、`preview` をそれぞれ承認する。両環境の UUID が同一とは仮定しない。
5. GitHub Actions の実行履歴とDB監査記録を照合する。`audit` に元の run ID を指定すると操作・actor・前後指紋を参照できる。DB記録と更新は原子的だが、actor/run ID は専用資格情報を使うクライアントから渡されるため、GitHub実行履歴との照合が必要。資格情報を持つ管理者からの偽装やDB管理者による改変に対する改ざん防止ログではない。

結果不明・接続切断時は再試行せず、同じ run ID の `audit` と新しい `preview` を照合して確定する。対象が不正、状態が変わった、監査が見つからない、または確認できない場合は停止して調査する。これらの操作を実行する前に個別の承認を得る。

## パスワード初期設定・再設定

Devと本番それぞれ同じ順序で独立に行う。各DB変更、Secret登録、例外設定はそれぞれ事前承認を得る。

1. 対象環境のReader migration planを確認し、別途承認された既存Writer applyとReader postflightを完了し、Writer flagをfalseに戻す。失敗・不明・identity不一致なら停止する。
2. 対象の既存apply Environmentに、その環境専用の新しいSecretを安全に登録する。Secretの登録自体はEnvironmentレビューを発生させないため、事前に別途承認を得る。値は安全な管理経路で発行し、ログ・入力欄・シェル履歴に記録しない。
3. `Provision AI quota admin password` をmainから対象を選び手動実行し、対象Environmentで承認する。workflowは最新main、Environment保護、Writer接続設定、同一接続でDB markerとpostgresのCREATEROLE・対象roleへのADMIN OPTION・対象role属性を検査する。libpqの `PQencryptPasswordConn` でSCRAM verifierを生成し、平文ではなくverifierを `ALTER ROLE` に渡す。DBログにverifierが残る可能性があり、verifierも機密としてDBログのアクセスを制限する。管理ロールや権限は追加しない。superuser以外には両権限が必要。新migrationでのロール作成者へのADMIN OPTIONはPostgreSQL 17の通常動作だが、hosted上では未確認であり、権限不足なら変更前に停止する。
4. 同じworkflowが専用ログインによる別接続でパスワード認証とDB identityを確認する。失敗やタイムアウトは更新済みか不明として扱い、再試行しない。Devでは承認付き `Verify Dev AI quota admin login (read-only)` で既存Secretによる認証とidentityを一度確認する。この診断は設定内容を読まない。失敗時はSecretと対象環境、実行履歴を管理者が確認する。復旧の再設定には新たな承認が必要。以前のSecretを上書きした場合、以前の接続は使えなくなる可能性がある。
5. 対象アカウントとpreview指紋を確認し、`set`を手動実行・Environment承認する。続いて別の承認付き `preview` で指紋を照合し、対象環境のOCR動作を確認する。各段階で不一致・エラー・結果不明なら停止し、auditとpreviewで確認する。

パスワード再設定は手順2〜4を再度行う。Dev完了後に本番も別途計画・承認し、同じ順序を繰り返す。workflowは失敗時にDBエラー本文や資格情報を表示しない。再設定時は一時的にアカウント管理workflowが使えなくなる可能性がある。対象アカウントのOCR例外はパスワード変更では切り替わらない。


## Devで初期設定結果が不明な場合

失敗したProvision workflowは再実行せず、Secretも変更しない。mainから `Verify Dev AI quota admin login (read-only)` を手動実行し、`development-db-apply` で承認する。既存 `DEV_AI_QUOTA_ADMIN_PASSWORD` と専用ログインだけを使い、Writer Secretは渡さない。DB identityを含む読取専用トランザクションを実行する。PASSはその時点でのSecretによるDev専用ログイン認証とidentityを示すが、例外設定や過去のALTERの実行履歴は示さない。認証エラーはSecret不一致、接続障害、Poolerの認証キャッシュなどを区別せず、パスワードが未変更だった証明にはならない。自動再試行せず調査する。`preview`、`set`、パスワード再設定には各々別途承認が必要。

Provisionの診断は固定の `stage` と `password_update` のみ記録する。`not_attempted` はALTER送信前、`unknown` はALTER送信後に結果を確定できない状態、`confirmed` はALTER成功応答を受信した状態である。プロセス中断等で段階メッセージがない場合も結果不明として扱う。秘密、verifier、DBエラー本文は出力しない。接続失敗はPoolerの認証失敗とネットワーク障害を区別しない。

## Devアプリ用backendログインの初期設定

この手順は `ai_quota_backend` 専用で、`ai_quota_admin_login` やWriterの資格情報をアプリに使わない。既存パスワードの管理場所が判明している場合はそれを使う。パスワードの有無は `pg_roles` では判定できず、Admin/Readerの成功もbackendログインの成功を示さない。

`Initialize Dev AI quota backend password` はDevのみ、mainの手動実行と既存 `development-db-apply` Environment承認が必要で、Writer接続を初期化操作に限って使用する。main SHA、Environment保護、接続先、DB identity、ロール属性、Writerの権限を確認し、`pg_authid` を短時間ロックした同一トランザクションで `rolpassword IS NULL` だけを照会する。既存パスワード、ロック不可、カタログ参照不可、不明状態では更新しない。ロックは他のロール更新を短時間待機させ得る。hosted SupabaseのWriterに必要な権限があるかは未検証で、不足時は停止し、権限追加や再設定を勝手に行わない。初期設定専用であり、ローテーションには使わない。ロール属性や権限は変更しない。

実行には別途承認が必要。次は将来の運用手順であり、PRの作成・マージだけではSecret登録や実行を行わない。

**DBログの事前確認:** SCRAM verifierは機密情報であり、サーバーのSQL文・監査ログに残る可能性がある。Devのログ設定、ログを閲覧・転送できる主体、保持期間と削除方針を、承認済みの管理者が確認し、必要最小限のアクセスと適切な保持方針を満たすことを確認してから実行する。設定・権限・保持方針が不明または不適切なら実行しない。GitHub ActionsのマスクやSecretはDB側ログを保護しない。

1. 安全なパスワードマネージャで英数字・ピリオド・アンダースコア・ハイフンのみの32〜128文字のランダム値を一度生成し、Dev backend専用として保存する。WriterやAdmin、Prodの値を使わない。
2. GitHubの `development-db-apply` Environmentに `DEV_AI_QUOTA_BACKEND_PASSWORD` として、保管した同じ値を登録する。Secret登録はEnvironmentレビューを発生させないため別途承認を要する。値をコマンド引数、ログ、チャットに書かない。
3. mainから対象workflowを実行し、Devのみであることを確認してEnvironment承認する。専用Secretを使う別接続でパスワード認証とDB identityを検証する。失敗時は再実行せず、`stage` と `password_update` を確認する。`not_attempted` は変更前、`unknown` はコミット成否不明、`confirmed` は更新済みで認証確認が未完了の可能性を示す。結果不明時は承認済み管理者が安全な方法で状態を確認する。verifierを含む可能性のあるDBログは上記の方針で保護する。
4. receipt-managerの `backend/.env.ai-quota` を所有者限定 `0600` で用意し、同じパスワードを安全なエディタで直接入力する。`AI_QUOTA_DB_HOST` はDev Session Pooler、`AI_QUOTA_DB_PORT=5432`、`AI_QUOTA_DB_NAME=postgres`、`AI_QUOTA_DB_USER=ai_quota_backend.irgahixsuvtopiwmtkku`、`AI_QUOTA_DB_PASSWORD` は保管した値、`AI_QUOTA_DB_SSLROOTCERT` はローカルで読めるCAの絶対パスとする。Git管理しない。`AI_QUOTA_ENV_FILE` で別の保護ファイルも指定できるが、通常のworktree setupはquotaファイルやCAを自動リンクしない。
5. DevのSupabase DashboardからCA証明書を取得し、保護されたローカルディレクトリに配置する。接続先を再確認し、`psql` の対話式パスワード入力、`sslmode=verify-full`、実際のCAパスで `BEGIN TRANSACTION READ ONLY; SELECT current_user; COMMIT;` だけを実行する。パスワードをコマンド引数や `.pgpass` に記録しない。両方で同じ保管値を入力したことを確認する。手入力のpsql認証成功だけではdotenvに保存した値との一致までは証明できない。読み取り確認はOCRやquota RPCを呼ばない。
6. receipt-managerを再起動し、quota設定不在のログが消えたことを確認する。設定後の別要因による接続失敗やOCR動作は別途検証する。

手順5の接続確認例。CAの絶対パスだけ実際のDev用ファイルに置き換え、パスワードは表示されない対話プロンプトで入力する。エラー本文には接続情報が含まれる場合があるため共有・記録しない。

```sh
psql -X -W "host=aws-1-ap-northeast-1.pooler.supabase.com port=5432 dbname=postgres user=ai_quota_backend.irgahixsuvtopiwmtkku sslmode=verify-full sslrootcert=<Dev用CAの絶対パス>" -c 'BEGIN TRANSACTION READ ONLY; SELECT current_user; COMMIT;'
```

出力の `current_user` が `ai_quota_backend` であることを確認する。CAの取得元とPoolerのホストは、実行時にもDevプロジェクトのSupabase Dashboardで確認する。
