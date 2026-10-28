-- Disposable test harness only. Not part of the migration and not used in production.
-- The migration revokes its temporary SET membership in ai_quota_owner. This
-- test-only bridge uses the disposable executor's ADMIN membership to grant
-- itself SET/INHERIT access for fixture DML and RPC calls.
\set ON_ERROR_STOP on

DO $need$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles
    WHERE rolname = current_user
      AND rolsuper
  ) THEN
    RAISE EXCEPTION 'disposable owner bridge is unnecessary for a superuser session';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_auth_members AS m
    JOIN pg_catalog.pg_roles AS granted ON granted.oid = m.roleid
    JOIN pg_catalog.pg_roles AS member ON member.oid = m.member
    WHERE granted.rolname = 'ai_quota_owner'
      AND member.rolname = current_user
      AND m.admin_option
  ) THEN
    RAISE EXCEPTION 'disposable ai_quota tests need ADMIN membership on ai_quota_owner';
  END IF;
END
$need$;

GRANT ai_quota_owner TO CURRENT_USER WITH SET TRUE, INHERIT TRUE, ADMIN FALSE;
