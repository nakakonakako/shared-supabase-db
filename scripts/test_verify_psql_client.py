"""Regression tests for runner client verification and workflow coverage."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERIFY = ROOT / "scripts/verify-psql-client.py"
WORKFLOWS = {
    "dev-migration-plan.yml": 1,
    "production-migration-plan.yml": 1,
    "dev-consumer-db-contract-check.yml": 1,
    "consumer-db-contract-check.yml": 1,
    "production-db-check.yml": 1,
    "verify-dev-db-writer-connection.yml": 2,
    "verify-production-db-writer-connection.yml": 2,
    "_apply-db-migrations.yml": 3,
}


class VerifyPsqlClientTests(unittest.TestCase):
    def run_client(self, script: str | None) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            if script is not None:
                executable = path / "psql"
                executable.write_text("#!/bin/sh\n" + script + "\n", encoding="utf-8")
                executable.chmod(0o700)
            return subprocess.run(
                [sys.executable, str(VERIFY)],
                env={"PATH": str(path), "PGPASSWORD": "private-test-secret", "PGHOST": "private-host"},
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )

    def test_reviewed_majors_pass(self) -> None:
        for version in ("17.9", "18.0", "18.6 (Ubuntu 18.6-1)"):
            with self.subTest(version=version):
                result = self.run_client(f"printf '%s\\n' 'psql (PostgreSQL) {version}'")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(version, result.stdout)
                self.assertNotIn("private-test-secret", result.stdout + result.stderr)

    def test_missing_unsupported_malformed_and_failing_clients_stop(self) -> None:
        cases = (
            None,
            "echo 'psql (PostgreSQL) 16.15'",
            "echo 'psql (PostgreSQL) 19.0'",
            "echo 'psql (PostgreSQL) 18'",
            "echo 'psql (PostgreSQL) 18.6 trailing text'",
            "echo 'psql (PostgreSQL) 18.6'; exit 1",
            "echo private-test-secret >&2; exit 1",
        )
        for script in cases:
            with self.subTest(script=script):
                result = self.run_client(script)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("private-test-secret", result.stdout + result.stderr)

    def test_version_probe_removes_password_but_preserves_wrapper_selection(self) -> None:
        result = self.run_client(
            "if [ -n \"${PGPASSWORD:-}\" ] || [ \"${PGHOST:-}\" != private-host ]; then exit 1; fi\n"
            "echo 'psql (PostgreSQL) 18.6'"
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_every_hosted_workflow_uses_the_same_check(self) -> None:
        workflow_dir = ROOT / ".github/workflows"
        for name, expected in WORKFLOWS.items():
            with self.subTest(workflow=name):
                text = (workflow_dir / name).read_text(encoding="utf-8")
                self.assertEqual(text.count("run: python3 scripts/verify-psql-client.py"), expected)
                self.assertNotIn("apt-get", text)
                self.assertNotIn("Install PostgreSQL client", text)
        for file in workflow_dir.glob("*.yml"):
            if file.name != "pr-ci.yml":
                self.assertNotIn("apt-get install -y -qq postgresql-client", file.read_text(encoding="utf-8"))
        for name, prefix in (
            ("consumer-db-contract-check.yml", "PROD"),
            ("dev-consumer-db-contract-check.yml", "DEV"),
            ("production-db-check.yml", "PROD"),
        ):
            text = (workflow_dir / name).read_text(encoding="utf-8")
            verify_step = text.split("- name: Verify PostgreSQL client", 1)[1].split("- name:", 1)[0]
            self.assertIn(f"PGHOST: ${{{{ vars.{prefix}_SUPABASE_POOLER_HOST }}}}", verify_step)
            self.assertIn('PGPORT: "5432"', verify_step)
        ci = (workflow_dir / "pr-ci.yml").read_text(encoding="utf-8")
        self.assertLess(ci.index("python3 scripts/verify-psql-client.py"), ci.index("npm run test:sql:ai-quota"))


if __name__ == "__main__":
    unittest.main()
