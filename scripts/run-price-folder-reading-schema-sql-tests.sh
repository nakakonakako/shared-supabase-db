#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"
: "${PRICE_FOLDER_READING_SCHEMA_TEST_DATABASE_URL:?Set PRICE_FOLDER_READING_SCHEMA_TEST_DATABASE_URL to a fresh disposable PostgreSQL 17 price_folder_reading_schema_test database}"

mapfile -t pg_config < <(python3 - <<'PY'
import os
from urllib.parse import urlparse

target = urlparse(os.environ["PRICE_FOLDER_READING_SCHEMA_TEST_DATABASE_URL"])
if target.hostname not in {"localhost", "127.0.0.1", "::1"}:
    raise SystemExit("Refusing folder-reading schema test: host must be localhost or loopback")
if target.path.lstrip("/") != "price_folder_reading_schema_test" or target.username != "postgres":
    raise SystemExit("Refusing folder-reading schema test: use the disposable price_folder_reading_schema_test database as postgres")
for value in (
    target.hostname or "",
    str(target.port or 5432),
    target.path.lstrip("/"),
    target.username or "",
    target.password or "",
):
    print(value)
PY
)
export PGHOST="${pg_config[0]}" PGPORT="${pg_config[1]}" PGDATABASE="${pg_config[2]}"
export PGUSER="${pg_config[3]}" PGPASSWORD="${pg_config[4]}" PGSSLMODE=disable PGCONNECT_TIMEOUT=5

database_name="$(psql -X -w -v ON_ERROR_STOP=1 -Atqc 'SELECT current_database()')"
server_version="$(psql -X -w -v ON_ERROR_STOP=1 -Atqc 'SHOW server_version_num')"
if [[ "$database_name" != price_folder_reading_schema_test || "$server_version" -lt 170000 || "$server_version" -ge 180000 ]]; then
  echo "Refusing folder-reading schema test: expected the dedicated PostgreSQL 17 database." >&2
  exit 1
fi

fresh="$(psql -X -w -v ON_ERROR_STOP=1 -Atqc "
  SELECT pg_catalog.to_regnamespace('auth') IS NULL
    AND pg_catalog.to_regclass('public.price_folders') IS NULL
    AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname IN ('anon', 'authenticated'))
")"
if [[ "$fresh" != t ]]; then
  echo "Refusing folder-reading schema test: database is not fresh and disposable." >&2
  exit 1
fi

psql -X -w -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE SCHEMA auth;
CREATE TABLE auth.users (id uuid PRIMARY KEY);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT NULL::uuid $$;

CREATE TABLE public.price_folders (
  id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name text NOT NULL,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamp with time zone NOT NULL,
  updated_at timestamp with time zone NOT NULL,
  CONSTRAINT price_folders_pkey PRIMARY KEY (id),
  CONSTRAINT price_folders_user_id_name_key UNIQUE (user_id, name),
  CONSTRAINT price_folders_name_not_blank CHECK (char_length(trim(name)) > 0),
  CONSTRAINT price_folders_user_id_id_key UNIQUE (user_id, id)
);
ALTER TABLE public.price_folders ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Enable ALL operations for users based on user_id" ON public.price_folders
  FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
REVOKE ALL ON TABLE public.price_folders FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.price_folders TO authenticated;

CREATE TABLE public.price_records (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  folder_id uuid NOT NULL,
  CONSTRAINT price_records_user_id_folder_id_fkey
    FOREIGN KEY (user_id, folder_id) REFERENCES public.price_folders(user_id, id) ON DELETE CASCADE
);
ALTER TABLE public.price_records ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Enable ALL operations for users based on user_id" ON public.price_records
  FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE TABLE public.price_memo_items (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  folder_id uuid NOT NULL,
  CONSTRAINT price_memo_items_user_id_folder_id_fkey
    FOREIGN KEY (user_id, folder_id) REFERENCES public.price_folders(user_id, id) ON DELETE CASCADE
);
ALTER TABLE public.price_memo_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Enable ALL operations for users based on user_id" ON public.price_memo_items
  FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-4000-8000-000000000001'),
  ('00000000-0000-4000-8000-000000000002');
INSERT INTO public.price_folders (id, user_id, name, sort_order, created_at, updated_at) VALUES
  ('10000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001', 'Milk（ぎゅうにゅう）', 2, '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z'),
  ('10000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000002', '豆腐（とうふ）', 5, '2026-10-02T00:00:00Z', '2026-10-02T00:00:00Z');
INSERT INTO public.price_records (id, user_id, folder_id) VALUES
  ('20000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001');
INSERT INTO public.price_memo_items (id, user_id, folder_id) VALUES
  ('30000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001');
SQL

psql -X -w -v ON_ERROR_STOP=1 -f supabase/migrations/20261101011951_price_folder_reading.sql

existing_rows="$(psql -X -w -v ON_ERROR_STOP=1 -Atqc "
  SELECT count(*) = 2
    AND bool_and(reading IS NULL)
    AND bool_and(
      (id = '10000000-0000-4000-8000-000000000001' AND user_id = '00000000-0000-4000-8000-000000000001' AND name = 'Milk（ぎゅうにゅう）' AND sort_order = 2 AND created_at = '2026-10-01T00:00:00Z' AND updated_at = '2026-10-01T00:00:00Z')
      OR (id = '10000000-0000-4000-8000-000000000002' AND user_id = '00000000-0000-4000-8000-000000000002' AND name = '豆腐（とうふ）' AND sort_order = 5 AND created_at = '2026-10-02T00:00:00Z' AND updated_at = '2026-10-02T00:00:00Z')
    )
  FROM public.price_folders
")"
[[ "$existing_rows" == t ]] || { echo "Existing folder rows changed or are not NULL in reading." >&2; exit 1; }

column_state="$(psql -X -w -v ON_ERROR_STOP=1 -Atqc "
  SELECT a.atttypid = 'text'::regtype AND NOT a.attnotnull
  FROM pg_catalog.pg_attribute a
  WHERE a.attrelid = 'public.price_folders'::regclass AND a.attname = 'reading' AND NOT a.attisdropped
")"
[[ "$column_state" == t ]] || { echo "reading is not nullable text." >&2; exit 1; }

psql -X -w -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO public.price_folders (id, user_id, name, sort_order, created_at, updated_at) VALUES
  ('10000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000001', 'Bread', 7, now(), now());
INSERT INTO public.price_folders (id, user_id, name, reading, sort_order, created_at, updated_at) VALUES
  ('10000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000001', 'Rice', 'こめ', 8, now(), now());
UPDATE public.price_folders SET reading = 'ごはん' WHERE id = '10000000-0000-4000-8000-000000000004';
SQL

insert_update_state="$(psql -X -w -v ON_ERROR_STOP=1 -Atqc "
  SELECT (SELECT reading IS NULL FROM public.price_folders WHERE id = '10000000-0000-4000-8000-000000000003')
     AND (SELECT reading = 'ごはん' FROM public.price_folders WHERE id = '10000000-0000-4000-8000-000000000004')
")"
[[ "$insert_update_state" == t ]] || { echo "reading NULL/INSERT/UPDATE behavior failed." >&2; exit 1; }

if psql -X -w -v ON_ERROR_STOP=1 -c "INSERT INTO public.price_folders (id, user_id, name, created_at, updated_at) VALUES ('10000000-0000-4000-8000-000000000005', '00000000-0000-4000-8000-000000000001', 'Milk（ぎゅうにゅう）', now(), now())" >/dev/null 2>&1; then
  echo "The existing (user_id, name) unique constraint was not enforced." >&2
  exit 1
fi
if psql -X -w -v ON_ERROR_STOP=1 -c "INSERT INTO public.price_folders (id, user_id, name, created_at, updated_at) VALUES ('10000000-0000-4000-8000-000000000006', '00000000-0000-4000-8000-000000000099', 'Invalid owner', now(), now())" >/dev/null 2>&1; then
  echo "The existing price_folders user foreign key was not enforced." >&2
  exit 1
fi
if psql -X -w -v ON_ERROR_STOP=1 -c "INSERT INTO public.price_records (id, user_id, folder_id) VALUES ('20000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000002')" >/dev/null 2>&1; then
  echo "The existing price_records owner/folder foreign key was not enforced." >&2
  exit 1
fi

catalog_state="$(psql -X -w -v ON_ERROR_STOP=1 -Atqc "
  SELECT
    (SELECT count(*) = 5 FROM pg_catalog.pg_constraint WHERE conrelid = 'public.price_folders'::regclass)
    AND (SELECT count(*) = 1 FROM pg_catalog.pg_constraint WHERE conrelid = 'public.price_records'::regclass AND conname = 'price_records_user_id_folder_id_fkey')
    AND (SELECT count(*) = 1 FROM pg_catalog.pg_constraint WHERE conrelid = 'public.price_memo_items'::regclass AND conname = 'price_memo_items_user_id_folder_id_fkey')
    AND (SELECT count(*) = 3 FROM pg_catalog.pg_policy WHERE polrelid IN ('public.price_folders'::regclass, 'public.price_records'::regclass, 'public.price_memo_items'::regclass))
    AND (SELECT bool_and(relrowsecurity) FROM pg_catalog.pg_class WHERE oid IN ('public.price_folders'::regclass, 'public.price_records'::regclass, 'public.price_memo_items'::regclass))
    AND (SELECT count(*) = 1 FROM public.price_records WHERE id = '20000000-0000-4000-8000-000000000001' AND folder_id = '10000000-0000-4000-8000-000000000001')
    AND (SELECT count(*) = 1 FROM public.price_memo_items WHERE id = '30000000-0000-4000-8000-000000000001' AND folder_id = '10000000-0000-4000-8000-000000000001')
")"
[[ "$catalog_state" == t ]] || { echo "Existing constraints, RLS, or folder references changed." >&2; exit 1; }

python3 - <<'PY'
import os

from scripts.db_contract import validate_contract, verify_catalog

contract = validate_contract({
    "format_version": 1,
    "app_id": "price-memo",
    "contract_version": "1.1.0",
    "capabilities": {
        "tables": [{
            "schema": "public",
            "name": "price_folders",
            "relation_kind": "table",
            "columns": [
                {"name": "id", "type": "uuid", "nullable": False},
                {"name": "user_id", "type": "uuid", "nullable": False},
                {"name": "name", "type": "text", "nullable": False},
                {"name": "sort_order", "type": "integer", "nullable": False},
                {"name": "created_at", "type": "timestamp with time zone", "nullable": False},
                {"name": "updated_at", "type": "timestamp with time zone", "nullable": False},
            ],
            "constraints": [
                {"kind": "primary_key", "columns": ["id"]},
                {"kind": "unique", "columns": ["user_id", "name"]},
                {"kind": "unique", "columns": ["user_id", "id"]},
                {
                    "kind": "foreign_key",
                    "columns": ["user_id"],
                    "references": {"table": "auth.users", "columns": ["id"]},
                    "on_delete": "cascade",
                },
            ],
            "rls": {
                "enabled": True,
                "forced": False,
                "policies": [{
                    "name": "Enable ALL operations for users based on user_id",
                    "command": "ALL",
                    "roles": ["authenticated"],
                }],
            },
            "privileges": [{
                "role": "authenticated",
                "allow": ["SELECT", "INSERT", "UPDATE", "DELETE"],
                "deny": ["TRUNCATE", "REFERENCES", "TRIGGER", "MAINTAIN"],
            }],
        }],
        "functions": [],
        "auth": {
            "foreign_keys": [{
                "table": "public.price_folders",
                "columns": ["user_id"],
                "references": "auth.users",
                "referenced_columns": ["id"],
                "on_delete": "cascade",
            }],
            "functions": ["auth.uid()"],
        },
    },
})
results = verify_catalog(contract, env=os.environ.copy())
failed = [result.label for result in results if not result.passed]
if failed:
    raise SystemExit(f"Existing price_folders DB contract fragment failed: {failed}")
print(f"PASS: existing price_folders contract fragment ({len(results)} catalog assertions); extra reading column is tolerated")
PY

echo 'PASS: folder-reading nullable-column migration preserves existing folder data, constraints, references, and RLS'
