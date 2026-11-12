# AI quota 開発者例外の管理

この仕組みは `developer_user_id` の設定・解除専用。各操作は手動起動し、対象の既存 `development-db-apply` / `production-db-apply` Environment の承認を通る。migration apply workflow と資格情報は別であり、Writer enable flag は使わない。main の最新コミット、Environment の承認と main 限定、接続先 project ref、DB 内 identity marker を照合し、不一致なら停止する。例外は OCR の日次 user/global 上限と未知利用ブレーカーを除外し、緊急停止・同時実行・月次計測費用上限は維持する。対象ユーザーの OCR は日次集計にも含まれない。

## 前提と権限

- この PR のマージは hosted DB を変更しないが、新 migration が未適用の間、shared inventory の `IN_SYNC` を必要とするアプリ配信 gate は停止する。Dev と本番の migration plan を別々に確認し、各環境の適用は別途明示承認する。Writer flag の有効化と復帰、適用、Reader postflight は既存の protected workflow に従う。
- migration は `ai_quota_admin_login` と NOLOGIN owner、固定関数、監査表を作る。ログインには関数実行権限だけを与え、設定表・監査表や Auth 表の直接権限は与えない。owner の設定表権限は必要な列に限る。Auth 妥当性のため postgres 所有の固定 `SECURITY DEFINER` 関数が限定照会する。一般 API ロールと backend に公開しない。
- 新ログインのパスワードは migration で設定しない。適用後、認可されたDB管理者が対象DB identityを確認した上で `\password ai_quota_admin_login` を対話式で設定し、それぞれの既存 Environment に `DEV_AI_QUOTA_ADMIN_PASSWORD` / `PROD_AI_QUOTA_ADMIN_PASSWORD` を別途安全に登録する。GitHub Environment / Secret の変更とDB上のパスワード設定は別途承認が必要。既存 Writer Secret を流用しない。
- Environment の main 限定・必須レビュー・管理者バイパス無効を維持する。設定を変えず読み取り専用で確認する。workflow は保護が欠けると停止する。承認前に実行概要の target、operation、期待する現在値と新しい値の指紋を確認する。入力UUIDは Actions の実行入力に残るため、閲覧権限を制限する。
- 対象 UUID は小文字の標準形式で、該当DBの確認済み・ログイン済み・非匿名・未削除・停止されていない Auth ユーザーである必要がある。メール等はログに出さない。承認者は対象アカウントを別の信頼できる経路で確認する。UUID のSHA-256は秘密化ではない。

## Dev 検証から本番への手順

1. Dev migration plan、別途承認された migration 適用・Reader postflight を実施し、専用資格情報を別途承認して設定する。migration の事前条件や適用成否は hosted 環境で未検証である。失敗時は中止し調査する。
2. main から `Dev AI quota integrity (Reader only)` を手動実行する。Dev Reader とDB marker・migration履歴・quota/管理権限を読み取り専用で確認する。既存の破壊的な隔離SQLテストは hosted DB では実行しない。このチェックは設定値や実際のOCR動作を確認しない。
3. `Manage AI quota developer exception` を Dev の `preview` で実行し、承認後の現在値の指紋を記録する。`set` に対象UUIDと preview 指紋を指定し、提案内容を確認して承認する。更新は行ロック・事前値照合・アカウント確認・更新後確認・監査記録を同一トランザクションで行う。別途 `preview` で結果を照合し、実際のOCR動作をDevで確認する。解除は最新の preview 指紋を指定して `clear` を承認する。
4. Dev の結果をレビュー後、本番の migration plan、別途承認された適用・Reader postflight、専用資格情報設定を実施する。対象本番アカウントと指紋を独立に確認し、本番の `preview`、`set`、`preview` をそれぞれ承認する。両環境の UUID が同一とは仮定しない。
5. GitHub Actions の実行履歴とDB監査記録を照合する。`audit` に元の run ID を指定すると操作・actor・前後指紋を参照できる。DB記録と更新は原子的だが、actor/run ID は専用資格情報を使うクライアントから渡されるため、GitHub実行履歴との照合が必要。資格情報を持つ管理者からの偽装やDB管理者による改変に対する改ざん防止ログではない。

結果不明・接続切断時は再試行せず、同じ run ID の `audit` と新しい `preview` を照合して確定する。対象が不正、状態が変わった、監査が見つからない、または確認できない場合は停止して調査する。これらの操作を実行する前に個別の承認を得る。
