"""Fail-closed input and workflow checks for the quota administrator."""
import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('quota_admin', ROOT / 'scripts/manage-ai-quota-developer.py')
admin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(admin)


class AdminInputTests(unittest.TestCase):
    def setUp(self):
        self.env = {'DB_TARGET': 'dev', 'ADMIN_OPERATION': 'set',
                    'ADMIN_USER_ID': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
                    'ADMIN_EXPECTED': 'none', 'GITHUB_ACTOR': 'reviewer', 'GITHUB_RUN_ID': '123'}

    def test_valid_set_and_clear(self):
        self.assertEqual(admin.validated_inputs(self.env)[1], 'set')
        self.env.update(ADMIN_OPERATION='clear', ADMIN_USER_ID='', ADMIN_EXPECTED='a' * 64)
        self.assertEqual(admin.validated_inputs(self.env)[1], 'clear')

    def test_invalid_inputs_fail_closed(self):
        for changes in ({'ADMIN_USER_ID': 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'},
                        {'ADMIN_USER_ID': '00000000-0000-0000-0000-000000000000'},
                        {'ADMIN_EXPECTED': ''}, {'DB_TARGET': 'other'},
                        {'GITHUB_RUN_ID': '0'}, {'ADMIN_AUDIT_RUN_ID': '123'}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                admin.validated_inputs({**self.env, **changes})

    def test_audit_requires_run_id(self):
        env = {**self.env, 'ADMIN_OPERATION': 'audit', 'ADMIN_USER_ID': '', 'ADMIN_EXPECTED': ''}
        with self.assertRaises(ValueError):
            admin.validated_inputs(env)
        env['ADMIN_AUDIT_RUN_ID'] = '123'
        self.assertEqual(admin.validated_inputs(env)[-1], '123')

    def test_workflow_uses_protected_environment_and_dedicated_credentials(self):
        workflow = (ROOT / '.github/workflows/ai-quota-developer-admin.yml').read_text()
        for required in ('workflow_dispatch:', 'scripts/check-writer-environment.py',
                         'development-db-apply', 'production-db-apply',
                         'ai_quota_admin_login.', 'DEV_AI_QUOTA_ADMIN_PASSWORD',
                         'PROD_AI_QUOTA_ADMIN_PASSWORD', 'scripts/assert-latest-main.py'):
            self.assertIn(required, workflow)
        self.assertNotIn('DB_WRITER_ENABLED', workflow)
        self.assertNotIn('SUPABASE_DB_PASSWORD', workflow)


if __name__ == '__main__':
    unittest.main()
