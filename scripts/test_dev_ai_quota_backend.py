"""Fail-closed tests for the Dev-only backend reset and diagnosis."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('reset_backend', ROOT / 'scripts/reset-dev-ai-quota-backend.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class BackendPasswordTests(unittest.TestCase):
    def test_invalid_target_or_secret_never_connects(self):
        with patch.object(mod, 'library') as lib, patch.dict(mod.os.environ, {'PGPASSWORD': 'a' * 40}):
            for target, password in [('production', 'b' * 40), ('dev', ''), ('dev', 'short'), ('dev', 'a' * 40)]:
                with self.subTest(target=target), self.assertRaises(mod.ProvisionError):
                    mod.provision(target, password, 'ignored')
            lib.assert_not_called()

    def test_confirmation_required_before_connection(self):
        with patch.dict(mod.os.environ, {'RESET_CONFIRMATION': '', 'AI_QUOTA_BACKEND_PASSWORD': 'b' * 40}, clear=True), patch.object(mod, 'provision') as provision:
            self.assertEqual(mod.main(), 2)
            provision.assert_not_called()

    def test_permissions_or_identity_denial_prevents_update(self):
        for index, stage in enumerate(('db_identity', 'target_role', 'writer_createrole', 'writer_admin_option')):
            responses = [None] + ['ok'] * index + ['denied']
            with self.subTest(stage=stage), patch.object(mod, 'library', return_value=Mock()), \
                 patch.object(mod, 'connect', return_value=1), patch.object(mod, 'query', side_effect=responses):
                with self.assertRaises(mod.ProvisionError) as result:
                    mod.provision('dev', 'b' * 40, 'ignored')
                self.assertEqual(str(result.exception), f'stage={stage}; password_update=not_attempted')

    def test_update_uncertain_and_auth_failure_are_redacted(self):
        for failure, expected in (('ALTER', 'stage=password_update; password_update=unknown'),
                                  ('login', 'stage=backend_authentication; password_update=confirmed')):
            pq = Mock()
            pq.PQencryptPasswordConn.return_value = 5
            def query(_pq, _conn, sql, expected_status=2):
                if sql.startswith('ALTER') and failure == 'ALTER':
                    raise RuntimeError('sensitive details')
                return 'ok' if expected_status == 2 else None
            connections = [1, mod.ProvisionError('sensitive details')] if failure == 'login' else [1]
            with self.subTest(failure=failure), patch.object(mod, 'library', return_value=pq), \
                 patch.object(mod, 'connect', side_effect=connections), patch.object(mod, 'query', side_effect=query), \
                 patch.object(mod.ctypes, 'string_at', return_value=b'SCRAM-SHA-256$4096:AA==$AA==:AA=='):
                with self.assertRaises(mod.ProvisionError) as result:
                    mod.provision('dev', 'b' * 40, 'ignored')
            self.assertEqual(str(result.exception), expected)

    def test_workflows_are_dev_only_protected_and_scoped(self):
        reset = (ROOT / '.github/workflows/dev-ai-quota-backend-password.yml').read_text()
        diagnostic = (ROOT / '.github/workflows/dev-ai-quota-backend-login-check.yml').read_text()
        for workflow in (reset, diagnostic):
            for item in ('workflow_dispatch:', 'development-db-apply', 'shared-supabase-db-migration-apply-dev',
                         'scripts/assert-latest-main.py', 'scripts/check-writer-environment.py', 'DEV_AI_QUOTA_BACKEND_PASSWORD'):
                self.assertIn(item, workflow)
            for item in ('PROD_', 'production-db-apply', 'inputs.target', '  push:'):
                self.assertNotIn(item, workflow)
        self.assertIn('reset-dev-ai-quota-backend', reset)
        self.assertIn('scripts/validate-writer-db-env.py', reset)
        self.assertNotIn('MIGRATION_SUPABASE_DB_PASSWORD', diagnostic)
        script = (ROOT / 'scripts/reset-dev-ai-quota-backend.py').read_text()
        self.assertNotIn('pg_authid', script)
        self.assertNotIn('pg_catalog.pg_authid', script)


if __name__ == '__main__':
    unittest.main()
