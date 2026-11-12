"""Static and fail-closed checks for the protected password workflow."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch, Mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('provision_admin', ROOT / 'scripts/provision-ai-quota-admin.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class PasswordTests(unittest.TestCase):
    def test_invalid_secret_or_target_never_connects(self):
        with patch.object(mod, 'library') as lib:
            for target, password in [('dev', ''), ('production', 'short'), ('bad', 'a' * 40), ('dev', 'x' * 33 + "'")]:
                with self.subTest(target=target, password=password), self.assertRaises(mod.ProvisionError):
                    mod.provision(target, password, 'ignored')
            lib.assert_not_called()

    def test_failures_report_fixed_stage_without_raw_error(self):
        with patch.object(mod, 'library', side_effect=OSError('sensitive raw error')):
            with self.assertRaises(mod.ProvisionError) as result:
                mod.provision('dev', 'a' * 40, 'ignored')
        self.assertEqual(str(result.exception), 'stage=libpq_initialization; password_update=not_attempted')

    def test_update_failure_never_claims_rollback(self):
        pq = Mock()
        pq.PQencryptPasswordConn.return_value = 5
        checks = [None, 'ok', 'ok', 'ok', 'ok']
        def query(_pq, _conn, sql, expected_status=2):
            if sql.startswith('ALTER ROLE'):
                raise RuntimeError('private database error')
            return checks.pop(0)
        with patch.object(mod, 'library', return_value=pq), patch.object(mod, 'connect', return_value=1), \
             patch.object(mod, 'query', side_effect=query), \
             patch.object(mod.ctypes, 'string_at', return_value=b'SCRAM-SHA-256$4096:AA==$AA==:AA=='):
            with self.assertRaises(mod.ProvisionError) as result:
                mod.provision('dev', 'a' * 40, 'ignored')
        self.assertEqual(str(result.exception), 'stage=password_update; password_update=unknown')

    def test_preflight_denials_have_distinct_fixed_stages(self):
        for index, stage in enumerate(('db_identity', 'target_role', 'writer_createrole', 'writer_admin_option')):
            responses = [None] + ['ok'] * index + ['denied']
            with self.subTest(stage=stage), patch.object(mod, 'library', return_value=Mock()), \
                 patch.object(mod, 'connect', return_value=1), \
                 patch.object(mod, 'query', side_effect=responses):
                with self.assertRaises(mod.ProvisionError) as result:
                    mod.provision('dev', 'a' * 40, 'ignored')
                self.assertEqual(str(result.exception), f'stage={stage}; password_update=not_attempted')

    def test_post_update_authentication_failure_reports_confirmed_update(self):
        pq = Mock()
        pq.PQencryptPasswordConn.return_value = 5
        with patch.object(mod, 'library', return_value=pq), \
             patch.object(mod, 'connect', side_effect=[1, mod.ProvisionError('raw detail')]), \
             patch.object(mod, 'query', side_effect=[None, 'ok', 'ok', 'ok', 'ok', None]), \
             patch.object(mod.ctypes, 'string_at', return_value=b'SCRAM-SHA-256$4096:AA==$AA==:AA=='):
            with self.assertRaises(mod.ProvisionError) as result:
                mod.provision('dev', 'a' * 40, 'ignored')
        self.assertEqual(str(result.exception), 'stage=admin_authentication; password_update=confirmed')

    def test_diagnostic_is_dev_only_and_secret_scoped(self):
        workflow = (ROOT / '.github/workflows/dev-ai-quota-admin-login-check.yml').read_text()
        self.assertIn('secrets.DEV_AI_QUOTA_ADMIN_PASSWORD', workflow)
        self.assertIn('development-db-apply', workflow)
        self.assertIn('scripts/check-writer-environment.py', workflow)
        self.assertNotIn('MIGRATION_SUPABASE_DB_PASSWORD', workflow)
        self.assertNotIn('PROD_', workflow)
        self.assertNotIn('  push:', workflow)

    def test_workflow_requires_main_protection_and_scoped_secrets(self):
        workflow = (ROOT / '.github/workflows/ai-quota-admin-password.yml').read_text()
        for item in ('workflow_dispatch:', 'refs/heads/main', 'scripts/assert-latest-main.py',
                     'scripts/check-writer-environment.py', 'scripts/validate-writer-db-env.py',
                     'development-db-apply', 'production-db-apply', 'DEV_AI_QUOTA_ADMIN_PASSWORD',
                     'PROD_AI_QUOTA_ADMIN_PASSWORD', 'scripts/provision-ai-quota-admin.py'):
            self.assertIn(item, workflow)
        self.assertNotIn('DB_WRITER_ENABLED', workflow)
        self.assertNotIn('  push:', workflow)


if __name__ == '__main__':
    unittest.main()
