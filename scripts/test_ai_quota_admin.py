"""Fail-closed input and workflow checks for the quota administrator."""
import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

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
                        {'ADMIN_EXPECTED': 'stale'}, {'DB_TARGET': 'other'},
                        {'GITHUB_RUN_ID': '0'}, {'ADMIN_AUDIT_RUN_ID': '123'}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                admin.validated_inputs({**self.env, **changes})

    def test_expected_fingerprint_is_optional_for_changes(self):
        self.env['ADMIN_EXPECTED'] = ''
        self.assertEqual(admin.validated_inputs(self.env)[3], '')
        self.env.update(ADMIN_OPERATION='clear', ADMIN_USER_ID='')
        self.assertEqual(admin.validated_inputs(self.env)[3], '')

    def run_main(self, outputs, expected=''):
        """Run main() against scripted psql results: (returncode, stdout) per call."""
        env = {**self.env, 'ADMIN_EXPECTED': expected}
        results = [subprocess.CompletedProcess([], code, out + '\n', 'private database detail') for code, out in outputs]
        out, err = io.StringIO(), io.StringIO()
        with patch.dict(admin.os.environ, env, clear=True), patch.object(admin, 'validate_connection'), \
             patch.object(admin.shutil, 'which', return_value='psql'), \
             patch.object(admin.subprocess, 'run', side_effect=results) as run, \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = admin.main()
        self.assertNotIn('private database detail', out.getvalue() + err.getvalue())
        self.assertNotIn(self.env['ADMIN_USER_ID'], out.getvalue() + err.getvalue())
        return code, out.getvalue(), err.getvalue(), run.call_count

    def test_change_verifies_audit_and_current_value(self):
        after = hashlib.sha256(self.env['ADMIN_USER_ID'].encode()).hexdigest()
        code, out, _, calls = self.run_main([(0, f'none|{after}'), (0, f'set|reviewer|none|{after}'), (0, after)])
        self.assertEqual((code, calls), (0, 3))
        self.assertIn('change committed', out)
        self.assertIn('verified: audit record for run 123', out)

    def test_failed_verification_reports_committed_change(self):
        after = hashlib.sha256(self.env['ADMIN_USER_ID'].encode()).hexdigest()
        audit = f'set|reviewer|none|{after}'
        for name, tail in (('missing audit', [(0, ''), (0, after)]),
                           ('other actor', [(0, f'set|someone|none|{after}'), (0, after)]),
                           ('value changed', [(0, audit), (0, 'none')]),
                           ('audit query failed', [(2, ''), (0, after)])):
            with self.subTest(name):
                code, out, err, _ = self.run_main([(0, f'none|{after}'), *tail])
                self.assertEqual(code, 2)
                self.assertIn('change committed', out)
                self.assertIn('committed but verification failed', err)
                self.assertNotIn('verified:', out)

    def test_rejected_or_mismatched_change_is_not_verified(self):
        after = hashlib.sha256(self.env['ADMIN_USER_ID'].encode()).hexdigest()
        for outputs, expected in (([(3, '')], ''), ([(0, f"{'a' * 64}|{after}")], 'none'), ([(0, f"none|{'b' * 64}")], '')):
            with self.subTest(outputs=outputs):
                code, out, _, calls = self.run_main(outputs, expected)
                self.assertEqual((code, calls), (2, 1))
                self.assertNotIn('change committed', out)

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
                         'PROD_AI_QUOTA_ADMIN_PASSWORD', 'scripts/assert-latest-main.py',
                         'manage-ai-quota-developer.py | tee -a "$GITHUB_STEP_SUMMARY"'):
            self.assertIn(required, workflow)
        self.assertNotIn('DB_WRITER_ENABLED', workflow)
        self.assertNotIn('SUPABASE_DB_PASSWORD', workflow)


if __name__ == '__main__':
    unittest.main()
