# アプリDB互換性契約

## 所有権

- migration本文とmigration履歴の正本は`shared-supabase-db`。
- 各アプリのDB契約本文の正本は、そのアプリリポジトリに置く。shared側へ契約本文をコピーして管理しない。
- shared側は契約形式、検証器、隔離環境テスト、診断ロジックを所有する。
- `scripts/fixtures/db-contract-v1.example.json`は検証用の架空契約であり、実アプリの契約を表さない。

## v1ファイル形式

UTF-8 JSONを使用する。未知のキー、未知のformat version、未対応の値はfail-closedで拒否する。JSONのオブジェクトキーは宣言的な検査条件であり、任意SQLや式を埋め込む仕組みは持たせない。

トップレベルのキーは次のとおり。

```json
{
  "format_version": 1,
  "app_id": "example-app",
  "contract_version": "1.0.0",
  "capabilities": {
    "tables": [],
    "functions": [],
    "auth": {},
    "realtime": {}
  }
}
```

- `format_version`: 検証器との互換形式。現在は整数`1`のみ。
- `app_id`: lowercase kebab-caseの識別子。
- `contract_version`: アプリ側契約のsemver。migration番号とは独立。
- `capabilities.tables`: schema/name、`relation_kind`、必須カラムの`format_type`文字列・NULL許可、PK/UNIQUE/FK、RLS有効/強制、名前・command・roleを持つ必須policy、role別必須/禁止権限（PostgreSQL 17の`MAINTAIN`を含む）、必須trigger。
- `capabilities.functions`: schema修飾済みシグネチャ、戻り型と`returns_set`、任意の全引数宣言（順序、名前、mode、型）、SECURITY INVOKER/DEFINER、必要な場合の`search_path`、EXECUTE許可/禁止role。
- `capabilities.auth`: `auth.users`を参照する必須FKと必須Auth関数シグネチャ。
- `capabilities.realtime`: 必須relationとRLS有効値、Realtime関数、必須trigger名と有効状態。

列やtableは要求分のみを宣言する。追加column/table/functionがあっても、それ自体では不一致にならない。`relation_kind`は任意で、省略時は通常table（`pg_class.relkind='r'`）を要求する。明示値は`table`、`partitioned_table`、`view`、`materialized_view`。

FKの`validated`も任意で、省略時は`true`（検証済み）を要求する。`NOT VALID`を一時的/意図的に許容する契約だけ`validated: false`を明記する。これにより検証状態を暗黙に許容しない。`ON DELETE SET NULL`のFKには任意の`set_null_columns`を指定できる。省略時は過去のv1契約との互換性を保つため`confdelsetcols`を照合せず、対象列を厳密には保証しない。指定時は`columns`の全列を同じ順序で列挙するとPostgreSQLの「全FK列をSET NULL」（`confdelsetcols IS NULL`）を要求し、それ以外の部分集合ならその列集合のみが対象であることを確認する。空配列、FK外の列、`ON DELETE SET NULL`以外への指定は拒否する。

RLS policyの`name`はPostgreSQLの引用符付き識別子として扱い、大文字・空白・引用符を含められる。UTF-8で63 byteを超える名前とNUL文字は拒否する。検証器は`pg_policies`の名前、command、role集合を正確に比較し、名前をUTF-8 hexからDB内で復元するため、任意のpolicy名がSQL構文として解釈されない。`USING` / `WITH CHECK`式やpolicyの実際のアクセス結果は検査しない。

table privilegeのenumにはPostgreSQL 17の`MAINTAIN`を含む。`allow` / `deny`は`pg_catalog.has_table_privilege`で実効権限を確認する。

関数の`returns_set`は任意で、省略時は`false`（scalar）を要求する。`SETOF`は`true`を明記する。通常functionであることも必ず確認し、procedure等を同じsignature・戻り型と誤認しない。`RETURNS TABLE`など出力引数を持つ関数は、`returns`にPostgreSQLカタログ上の戻り型を記し、全`arguments`（出力列名・mode・型）を宣言して照合する。`record`戻り型は出力列を宣言しない契約を拒否する。戻り型と`proretset`は独立に照合し、未宣言のSETOFやPROCEDUREを成功扱いしない。

`arguments`は任意。指定する場合は**IN/OUT/INOUT/VARIADIC/TABLEを含む全引数**を宣言し、順序・名前・mode・型をカタログと完全照合する。`name: null`はその位置の引数に名前がないことを要求する。名前付き引数が一つもない関数ではPostgreSQLの`proargnames IS NULL`を期待する。`arguments`自体を省略した場合、引数名は契約条件に含めず、`proargmodes IS NULL`（すべてIN引数）だけを要求する。Supabase RPCなど名前付き引数の互換性が必要な関数では必ず宣言する。

これらの追加キーはv1で任意とし、省略時の上記既定値で既存契約を維持する。必須要素が欠落、改名、型/NULL制約変更、制約・関数security/引数/戻り形式・実行権限・RLS catalog設定・trigger状態に不一致があれば失敗する。

v1はFKの列、参照先、ON DELETE動作を検査し、`set_null_columns`がある場合は`pg_constraint.confdelsetcols`も照合する。省略時はこの列単位の動作を保証しない。チェック制約の任意式、列default、index形状、policyの`USING`/`WITH CHECK`式、関数本体や結果shapeは現状の対応範囲外。ロール所有者・属性・所属やschema ACLも保証しない。これらをcontractへ追加して成功扱いにはせず、必要になった時点で明示的にschema versionを拡張し、隔離テストを追加する。

## コマンドと結果の意味

```sh
# JSON形式だけを検査。DBには接続しない
python3 scripts/check-db-contract.py path/to/contract.json --validate-only

# JSONと現在の接続先カタログを検査
python3 scripts/check-db-contract.py path/to/contract.json
```

カタログ検査は`psql`を一度呼び出し、全assertionを`BEGIN TRANSACTION READ ONLY`内の単一statementとして実行する。statement timeoutを設定し、必要オブジェクト、型、NULL許可、制約、関数属性、effective grants、RLSフラグ/policyメタデータ、Auth/Realtimeの参照オブジェクトを照合する。業務テーブルの行をSELECTしない。接続失敗、SQL失敗、assertion数や出力形式の不一致は成功と解釈しない。

`STATIC PASS`はカタログ上の宣言条件が合ったという結果だけである。次の動作は合成ユーザー/行を用いた使い捨て環境で別途検証する。

- RLSが利用者自身の行だけを許し、別利用者の行を遮断すること
- Auth/JWT claim下でのINSERT/UPDATE `WITH CHECK`とデータ分離
- RPCの戻り値、エラー、トランザクション/同時実行動作
- Realtimeの認証、topic分離、実際のbroadcast配信
- migrationを新規DBへ適用できること

## 契約原本の取得とSHA固定

契約本文はアプリリポジトリ内のファイルを正本とし、shared側には複製しない。shared側の参照は`repository`、`path`、完全な40桁commit SHAで固定し、branch/tag名には追従しない。現在の初期検証revisionは`price-memo`の`7620cc8e43ef1defeaa0700d6ad0d509097ae52d`と`receipt-manager`の`2c6803cdd7dbc31d441c822df23027f2ddc3f6ce`。このSHAは実際の本番稼働revisionを表さない。

`scripts/consumer_db_contracts.py`はGitHub公開Commit APIで指定SHAと応答の完全一致を確認し、その後`raw.githubusercontent.com/<repo>/<sha>/<path>`から取得する。トークンや追加Secretは使用しない。取得、SHA確認、UTF-8 JSON decode、v1形式、期待する`app_id`のいずれかが失敗した場合はDB照合へ進まない。契約ファイルはworkflow runnerの一時領域にだけ保存する。

`.github/workflows/consumer-db-contract-check.yml`は`workflow_dispatch`専用でmainからのみ実行でき、最新main SHAを確認する。DB接続前のstepで両契約の取得と形式検証を完了し、既存`production-db-check` Environmentの`migration_preflight_login`資格情報を使って各契約を別々のread-only transactionで照合する。結果は契約ごとに`STATIC PASS`、`CONTRACT MISMATCH`、`EXECUTION ERROR`を出し、両方の成功時だけaggregateを成功とする。接続・出力形式・取得・形式の不明結果はfail-closed。migration履歴照合は既存のproduction workflowで独立して扱い、この契約workflowでは実施しない。

PR CIはホストDBやReader資格情報を利用しない。両アプリの契約PR・CIはアプリリポジトリ側の所有範囲とし、shared側workflowは明示された固定revisionのみを検証する。

## 後方互換性とbreaking change

通常のDB変更は既存契約をすべて満たし続ける後方互換変更とする。新しい任意column/table/RPCは許容するが、既存必須columnの削除/改名、型・NULL制約・PK/FK/UNIQUE変更、RPCシグネチャ/戻り型/security/EXECUTE変更、RLS/ACLの不一致は少なくとも一つの現行契約を落とす。

breaking変更が必要な場合はexpand/contractで分割する。先に新しい列/RPCを追加し、両アプリが旧・新schemaで動く期間を確保する。旧アプリの契約revisionが稼働対象から外れたことを確認してから削除migrationを検討する。アプリ側が契約を変更するPRでは、契約変更の理由と実際のコード参照も同じレビューで確認する。

アプリ互換性判定はmigration履歴全件の一致に依存しない。sharedの運用では既存のDev/Prod migration履歴照合を別の健全性ゲートとして維持する。必要な構造・権限を満たすことと、DB全体のmigration履歴が同じことは別判定である。

## 今後のActions連携方式

| 方式 | 資格情報 | 保守・簡潔さ | 評価 |
|---|---|---|---|
| shared側reusable workflowを完全SHA固定 | 呼び出し先workflowのjobにEnvironmentを定義すると、呼び出し側repoに同名Environmentが必要。`workflow_call`からEnvironment secretは直接渡せず、空値を明示検査する必要がある | job全体と分岐を集約できるが、Environment/secretsの暗黙境界が分かりにくい | workflow全体を中央管理したい場合に適する |
| appのEnvironment job内でshared側composite actionを完全SHA固定 | app repoのjobがEnvironmentを直接指定し、必要なReader値だけをstep envへ明示的に渡す | appはtrigger/job条件を保持し、共通SQL/検証コードを一箇所で保守できる | **推奨**。Reader資格情報の所在がapp repoのEnvironment/jobに明確で、既存deploy gateへ最小差分で組み込みやすい |
| 検証スクリプトをSHA固定checkoutして実行 | caller jobのEnvironmentを利用できるが、別repo checkout権限とtokenの扱いが必要 | action配布よりstepが増え、checkout/パス/認証を各appが実装する | composite actionの配布が難しい場合の代案 |

どの方式でも`permissions: contents: read`、action及びsharedコードの完全SHA固定、DB資格情報のstep/job scope限定、未設定・取得失敗・不明結果のfail-closedを必須とする。shared repoがprivateの場合は、Actions設定で2アプリからの読み取り利用を許可する作業が別途必要。PR検査は使い捨てDBのみとし、本番Reader資格情報をPRコードへ渡さない。
