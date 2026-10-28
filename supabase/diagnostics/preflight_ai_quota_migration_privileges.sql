-- Read-only privilege preflight BEFORE applying the ai_quota migration.
-- Run once, as the role that would apply
-- supabase/migrations/20261014120000_s1_06_ai_quota_foundation.sql.
-- Displays catalog facts only. No writes, role changes, passwords, hosts, or
-- connection strings. This script does not change the database.
--
-- This check is only for a first apply. If ai_quota_owner or ai_quota_backend
-- already exists, it fails closed and does not authorize reuse or ALTER ROLE.
-- The migration itself also refuses those existing roles.
-- An exception, a missing fact, or an unclear result means: stop deploy and migration.
-- Completion without an exception does NOT prove CREATE ROLE, the temporary
-- GRANT of database CREATE to ai_quota_owner, CREATE SCHEMA AUTHORIZATION,
-- SET ROLE, or SECURITY DEFINER functions will succeed. The executor must be
-- able to GRANT CREATE on the target database. A read-only catalog check
-- cannot fully prove that temporary GRANT will succeed. rolcreaterole alone
-- is not that proof.

\set ON_ERROR_STOP on

BEGIN TRANSACTION READ ONLY;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '15s';

SELECT section, item, observation
FROM (
  SELECT
    'session'::text AS section,
    'current_user'::text AS item,
    current_user::text AS observation,
    10 AS sort_key
  UNION ALL
  SELECT
    'session',
    'session_user',
    session_user::text,
    20
  UNION ALL
  SELECT
    'session',
    'server_version',
    pg_catalog.current_setting('server_version'),
    30
  UNION ALL
  SELECT
    'current_role_flags',
    f.flag,
    f.observation,
    40
  FROM pg_catalog.pg_roles AS r
  CROSS JOIN LATERAL (
    VALUES
      ('rolsuper', r.rolsuper::text),
      ('rolcreaterole', r.rolcreaterole::text),
      ('rolcreatedb', r.rolcreatedb::text),
      ('rolcanlogin', r.rolcanlogin::text),
      ('rolinherit', r.rolinherit::text),
      ('rolreplication', r.rolreplication::text),
      ('rolbypassrls', r.rolbypassrls::text)
  ) AS f(flag, observation)
  WHERE r.rolname = current_user
  UNION ALL
  SELECT
    'database_privilege',
    'CREATE',
    pg_catalog.has_database_privilege(
      current_user,
      pg_catalog.current_database(),
      'CREATE'
    )::text,
    50
  UNION ALL
  SELECT
    'database_privilege',
    'CREATE WITH GRANT OPTION',
    pg_catalog.has_database_privilege(
      current_user,
      pg_catalog.current_database(),
      'CREATE WITH GRANT OPTION'
    )::text,
    55
  UNION ALL
  SELECT
    'database_owner',
    pg_catalog.current_database(),
    pg_catalog.pg_get_userbyid(d.datdba),
    56
  FROM pg_catalog.pg_database AS d
  WHERE d.datname = pg_catalog.current_database()
  UNION ALL
  SELECT
    'membership',
    granted.rolname,
    pg_catalog.format(
      'grantor=%s admin_option=%s set_option=%s inherit_option=%s',
      pg_catalog.pg_get_userbyid(m.grantor),
      m.admin_option,
      m.set_option,
      m.inherit_option
    ),
    60
  FROM pg_catalog.pg_auth_members AS m
  JOIN pg_catalog.pg_roles AS granted ON granted.oid = m.roleid
  JOIN pg_catalog.pg_roles AS member ON member.oid = m.member
  WHERE member.rolname = current_user
  UNION ALL
  SELECT
    'target_role',
    candidate.rolname,
    CASE
      WHEN existing.rolname IS NULL THEN 'absent'
      ELSE pg_catalog.format(
        'present super=%s createrole=%s createdb=%s canlogin=%s inherit=%s replication=%s bypassrls=%s',
        existing.rolsuper,
        existing.rolcreaterole,
        existing.rolcreatedb,
        existing.rolcanlogin,
        existing.rolinherit,
        existing.rolreplication,
        existing.rolbypassrls
      )
    END,
    70
  FROM (
    VALUES
      ('ai_quota_owner'),
      ('ai_quota_backend'),
      ('anon'),
      ('authenticated'),
      ('service_role')
  ) AS candidate(rolname)
  LEFT JOIN pg_catalog.pg_roles AS existing ON existing.rolname = candidate.rolname
  UNION ALL
  SELECT
    'target_role_admin',
    candidate.rolname,
    CASE
      WHEN existing.oid IS NULL THEN 'role_absent'
      WHEN pg_catalog.pg_has_role(current_user, existing.oid, 'MEMBER') IS TRUE
        THEN pg_catalog.format(
          'member admin_option=%s',
          coalesce((
            SELECT m.admin_option::text
            FROM pg_catalog.pg_auth_members AS m
            WHERE m.roleid = existing.oid
              AND m.member = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = current_user)
          ), 'indirect_or_unknown')
        )
      ELSE 'not_a_member'
    END,
    80
  FROM (
    VALUES ('ai_quota_owner'), ('ai_quota_backend')
  ) AS candidate(rolname)
  LEFT JOIN pg_catalog.pg_roles AS existing ON existing.rolname = candidate.rolname
  UNION ALL
  SELECT
    'schema',
    'ai_quota',
    CASE
      WHEN n.oid IS NULL THEN 'absent'
      ELSE pg_catalog.format('owner=%s', pg_catalog.pg_get_userbyid(n.nspowner))
    END,
    90
  FROM (SELECT 1) AS seed
  LEFT JOIN pg_catalog.pg_namespace AS n ON n.nspname = 'ai_quota'
  UNION ALL
  SELECT
    'function',
    coalesce(p.proname, 'ai_quota'),
    CASE
      WHEN p.oid IS NULL THEN 'absent'
      ELSE pg_catalog.format(
        'owner=%s security_definer=%s',
        pg_catalog.pg_get_userbyid(p.proowner),
        p.prosecdef
      )
    END,
    100
  FROM (SELECT 1) AS seed
  LEFT JOIN pg_catalog.pg_namespace AS n ON n.nspname = 'ai_quota'
  LEFT JOIN pg_catalog.pg_proc AS p ON p.pronamespace = n.oid
) AS observations
ORDER BY sort_key, section, item;

DO $preflight$
DECLARE
  v_super boolean;
  v_createrole boolean;
  v_can_create_in_db boolean;
  v_can_grant_create boolean;
  v_schema_exists boolean;
  v_missing_targets text;
  v_missing_api_roles text;
  v_existing_targets text;
  v_reason text := '';
BEGIN
  SELECT r.rolsuper, r.rolcreaterole
    INTO v_super, v_createrole
  FROM pg_catalog.pg_roles AS r
  WHERE r.rolname = current_user;

  IF v_super IS NULL THEN
    RAISE EXCEPTION 'ai_quota migration privilege preflight insufficient; stop deploy and migration. current role is not visible in pg_roles';
  END IF;

  v_can_create_in_db := pg_catalog.has_database_privilege(
    current_user,
    pg_catalog.current_database(),
    'CREATE'
  );
  v_can_grant_create := pg_catalog.has_database_privilege(
    current_user,
    pg_catalog.current_database(),
    'CREATE WITH GRANT OPTION'
  );
  v_schema_exists := pg_catalog.to_regnamespace('ai_quota') IS NOT NULL;

  SELECT pg_catalog.string_agg(candidate.rolname, ', ' ORDER BY candidate.rolname)
    INTO v_missing_targets
  FROM (VALUES ('ai_quota_owner'), ('ai_quota_backend')) AS candidate(rolname)
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles AS r WHERE r.rolname = candidate.rolname
  );

  SELECT pg_catalog.string_agg(candidate.rolname, ', ' ORDER BY candidate.rolname)
    INTO v_missing_api_roles
  FROM (VALUES ('anon'), ('authenticated'), ('service_role')) AS candidate(rolname)
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles AS r WHERE r.rolname = candidate.rolname
  );

  SELECT pg_catalog.string_agg(existing.rolname, ', ' ORDER BY existing.rolname)
    INTO v_existing_targets
  FROM pg_catalog.pg_roles AS existing
  WHERE existing.rolname IN ('ai_quota_owner', 'ai_quota_backend');

  IF v_existing_targets IS NOT NULL THEN
    v_reason := v_reason || 'existing role present (' || v_existing_targets
      || '): this preflight only checks a first apply and will not authorize ALTER ROLE or reuse of an existing role. ';
  END IF;

  IF v_missing_targets IS NOT NULL AND v_super IS NOT TRUE AND v_createrole IS NOT TRUE THEN
    v_reason := v_reason || 'cannot create missing roles (' || v_missing_targets
      || '): current role is not superuser and lacks CREATEROLE. ';
  END IF;

  IF v_schema_exists IS NOT TRUE AND v_can_create_in_db IS NOT TRUE THEN
    v_reason := v_reason || 'cannot CREATE SCHEMA: current role lacks CREATE on this database and schema ai_quota is absent. ';
  END IF;

  IF v_can_grant_create IS NOT TRUE THEN
    v_reason := v_reason || 'cannot confirm GRANT CREATE on this database to ai_quota_owner: current role lacks CREATE WITH GRANT OPTION. The migration grants that privilege only for schema creation and then revokes it. A read-only catalog check cannot fully prove the temporary GRANT will succeed. ';
  END IF;

  IF v_missing_api_roles IS NOT NULL THEN
    v_reason := v_reason || 'migration REVOKE targets are absent (' || v_missing_api_roles || '). ';
  END IF;

  IF v_reason <> '' THEN
    RAISE EXCEPTION 'ai_quota migration privilege preflight insufficient; stop deploy and migration. %', v_reason;
  END IF;

  RAISE NOTICE 'ai_quota migration privilege preflight found no observable privilege gap for a first apply. The migration temporarily grants database CREATE to ai_quota_owner and effective SET membership to the executor, then revokes those temporary grants. The platform may retain an ADMIN-only role membership for the trusted executor; read-only preflight cannot prove how CREATE ROLE is wrapped by platform roles. rolcreaterole and CREATE WITH GRANT OPTION do not prove CREATE ROLE, temporary GRANT, CREATE SCHEMA AUTHORIZATION, SET ROLE, or SECURITY DEFINER migration will succeed. A read-only catalog check cannot fully prove temporary GRANT CREATE. If any displayed fact is missing or unclear, stop deploy and migration.';
END
$preflight$;

COMMIT;
