-- Disposable test harness only. Revoke the membership granted by
-- enable_disposable_owner_access.sql. Not part of the migration.
\set ON_ERROR_STOP on

REVOKE ai_quota_owner FROM CURRENT_USER;
