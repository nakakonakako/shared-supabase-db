"""Static and fail-closed checks for the protected password workflow."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

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
