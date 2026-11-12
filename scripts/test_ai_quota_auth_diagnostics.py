"""Read-only diagnostic control flow and secret-safe output tests."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('auth_diagnostics', ROOT / 'scripts/diagnose-dev-ai-quota-auth.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class DiagnosticTests(unittest.TestCase):
    def test_fixed_error_categories_never_expose_source(self):
        for text, category in [('password authentication failed secret', 'authentication'), ('timed out secret', 'timeout'),
                               ('could not translate host name secret', 'dns'), ('circuit breaker open secret', 'circuit_breaker'),
                               ('certificate verify failed secret', 'tls'), ('anything secret', 'other_connection_error')]:
            self.assertEqual(mod.error_category(text), category)
            self.assertNotIn('secret', mod.error_category(text))

    def test_invalid_configuration_fails_before_secrets_or_network(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(mod, 'diagnose') as diag:
            self.assertEqual(mod.main(), 2)
            diag.assert_not_called()

    def test_identity_failure_stops_before_role_password_or_admin(self):
        pq = Mock()
        pq.PQconnectionUsedPassword.return_value = 1
        output = io.StringIO()
        with contextlib.redirect_stdout(output), patch.object(mod.lib, 'library', return_value=pq), \
             patch.object(mod, 'open_connection', return_value=(1, None)) as conn, \
             patch.object(mod.lib, 'query', side_effect=[None, 'denied']) as query:
            self.assertEqual(mod.diagnose('a' * 40), 2)
        self.assertEqual(conn.call_count, 1)
        self.assertEqual(query.call_count, 2)
        self.assertIn('db_identity: FAIL (mismatch)', output.getvalue())
        self.assertNotIn('a' * 40, output.getvalue())

    def test_password_state_unavailable_still_checks_login(self):
        pq = Mock()
        pq.PQconnectionUsedPassword.return_value = 1
        pq.PQconnectionUsedPassword.return_value = 1
        output = io.StringIO()
        answers = [None, 'ok', 'ok', 'no', None, None, 'ok', None]
        with contextlib.redirect_stdout(output), patch.object(mod.lib, 'library', return_value=pq), \
             patch.object(mod, 'open_connection', side_effect=[(1, None), (2, None)]), \
             patch.object(mod.lib, 'query', side_effect=answers):
            self.assertEqual(mod.diagnose('a' * 40), 0)
        self.assertIn('password_state: UNKNOWN (insufficient_catalog_privilege)', output.getvalue())
        self.assertIn('admin_authentication: PASS', output.getvalue())
        self.assertNotIn('a' * 40, output.getvalue())

    def test_password_catalog_returns_only_boolean_state(self):
        for state in ('set', 'unset'):
            pq = Mock()
            pq.PQconnectionUsedPassword.return_value = 1
            output = io.StringIO()
            answers = [None, 'ok', 'ok', 'yes', state, None, None, 'ok', None]
            with self.subTest(state=state), contextlib.redirect_stdout(output), \
                 patch.object(mod.lib, 'library', return_value=pq), \
                 patch.object(mod, 'open_connection', side_effect=[(1, None), (2, None)]), \
                 patch.object(mod.lib, 'query', side_effect=answers) as query:
                self.assertEqual(mod.diagnose('a' * 40), 0 if state == 'set' else 1)
            statements = [args.args[2] for args in query.call_args_list]
            self.assertTrue(any("rolpassword IS NULL" in sql for sql in statements))
            self.assertTrue(all(sql.startswith(('BEGIN TRANSACTION READ ONLY', 'SELECT', 'COMMIT')) for sql in statements))
            self.assertNotIn('a' * 40, output.getvalue())

    def test_missing_secret_does_not_suppress_writer_checks(self):
        pq = Mock()
        pq.PQconnectionUsedPassword.return_value = 1
        output = io.StringIO()
        with contextlib.redirect_stdout(output), patch.object(mod.lib, 'library', return_value=pq), \
             patch.object(mod, 'open_connection', return_value=(1, None)) as conn, \
             patch.object(mod.lib, 'query', side_effect=[None, 'ok', 'ok', 'no', None]):
            self.assertEqual(mod.diagnose(''), 2)
        self.assertIn('secret_format: FAIL (missing_or_invalid)', output.getvalue())
        self.assertIn('writer_connection: PASS', output.getvalue())
        self.assertEqual(conn.call_count, 1)

    def test_workflow_is_manual_dev_only_and_protected(self):
        text = (ROOT / '.github/workflows/dev-ai-quota-auth-diagnostics.yml').read_text()
        for value in ('workflow_dispatch:', 'development-db-apply', 'DB_TARGET: dev',
                      'scripts/check-writer-environment.py', 'scripts/assert-latest-main.py',
                      'DEV_AI_QUOTA_ADMIN_PASSWORD', 'DEV_MIGRATION_SUPABASE_DB_PASSWORD'):
            self.assertIn(value, text)
        self.assertNotIn('PROD_', text)
        self.assertNotIn('DB_WRITER_ENABLED', text)
        self.assertNotIn('  push:', text)


if __name__ == '__main__':
    unittest.main()
