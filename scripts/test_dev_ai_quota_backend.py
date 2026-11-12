"""Fail-closed tests for the Dev-only backend credential workflow."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('provision_backend', ROOT / 'scripts/provision-dev-ai-quota-backend.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class BackendPasswordTests(unittest.TestCase):
    def test_invalid_inputs_never_connect(self):
        with patch.object(mod, 'library') as lib:
            for target, password in [('production', 'a' * 40), ('dev', ''), ('dev', 'short')]:
                with self.subTest(target=target), self.assertRaises(mod.ProvisionError):
                    mod.provision(target, password, 'ignored')
            lib.assert_not_called()

    def test_existing_password_never_updated(self):
        statements = []
        def query(_pq, _conn, sql, expected_status=2):
            statements.append(sql)
            if 'rolpassword IS NULL' in sql:
                return 'set'
            return 'ok' if expected_status == 2 else None
        with patch.object(mod, 'library', return_value=Mock()), patch.object(mod, 'connect', return_value=1), patch.object(mod, 'query', side_effect=query):
            with self.assertRaises(mod.ProvisionError) as result:
                mod.provision('dev', 'a' * 40, 'ignored')
        self.assertEqual(str(result.exception), 'stage=password_state; password_update=not_attempted')
        self.assertFalse(any(sql.startswith('ALTER ROLE') for sql in statements))
        self.assertTrue(any('LOCK TABLE pg_catalog.pg_authid' in sql for sql in statements))

    def test_catalog_access_failure_is_redacted(self):
        def query(_pq, _conn, sql, expected_status=2):
            if 'LOCK TABLE' in sql:
                raise RuntimeError('secret error')
            return 'ok' if expected_status == 2 else None
        with patch.object(mod, 'library', return_value=Mock()), patch.object(mod, 'connect', return_value=1), patch.object(mod, 'query', side_effect=query):
            with self.assertRaises(mod.ProvisionError) as result:
                mod.provision('dev', 'a' * 40, 'ignored')
        self.assertEqual(str(result.exception), 'stage=password_state_lock; password_update=not_attempted')

    def test_commit_failure_and_login_failure_are_not_misreported(self):
        for failure, expected in (('COMMIT', 'stage=password_commit; password_update=unknown'),
                                  ('login', 'stage=backend_authentication; password_update=confirmed')):
            pq = Mock()
            pq.PQencryptPasswordConn.return_value = 5
            def query(_pq, _conn, sql, expected_status=2):
                if sql == failure:
                    raise RuntimeError('private database details')
                if 'rolpassword IS NULL' in sql:
                    return 'unset'
                return 'ok' if expected_status == 2 else None
            connections = [1, mod.ProvisionError('private authentication details')] if failure == 'login' else [1]
            with self.subTest(failure=failure), patch.object(mod, 'library', return_value=pq), \
                 patch.object(mod, 'connect', side_effect=connections), patch.object(mod, 'query', side_effect=query), \
                 patch.object(mod.ctypes, 'string_at', return_value=b'SCRAM-SHA-256$4096:AA==$AA==:AA=='):
                with self.assertRaises(mod.ProvisionError) as result:
                    mod.provision('dev', 'a' * 40, 'ignored')
            self.assertEqual(str(result.exception), expected)

    def test_workflow_is_dev_only_and_protected(self):
        workflow = (ROOT / '.github/workflows/dev-ai-quota-backend-password.yml').read_text()
        for item in ('workflow_dispatch:', 'development-db-apply', 'shared-supabase-db-migration-apply-dev',
                     'scripts/assert-latest-main.py', 'scripts/check-writer-environment.py',
                     'scripts/validate-writer-db-env.py', 'secrets.DEV_AI_QUOTA_BACKEND_PASSWORD'):
            self.assertIn(item, workflow)
        for item in ('PROD_', 'production-db-apply', 'inputs.target', '  push:'):
            self.assertNotIn(item, workflow)


if __name__ == '__main__':
    unittest.main()
