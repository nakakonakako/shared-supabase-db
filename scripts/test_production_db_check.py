#!/usr/bin/env python3
"""Mock-only tests for the manual production Reader verification gate."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HISTORY_CHECKER = ROOT / "scripts/check-migration-history.py"
INTEGRITY_RUNNER = ROOT / "scripts/verify-production-db-integrity.py"
ENV_VALIDATOR = ROOT / "scripts/validate-production-db-env.py"
LATEST_MAIN = ROOT / "scripts/assert-latest-main.py"
DIAGNOSTICS = (
    "verify_production_db_reader.sql",
    "verify_migration_reader_bootstrap.sql",
    "verify_s1_08_rpc_integrity.sql",
    "verify_s1_06_ai_quota_integrity.sql",
    "verify_s1_f01_acl_integrity.sql",
)


class ProductionDbCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="production-reader-check-test-")
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.fake_psql = self.bin / "psql"
        self.fake_psql.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "args = sys.argv[1:]\n"
            "if '-c' in args:\n"
            " if os.environ.get('FAKE_HISTORY_ERROR') == '1':\n"
            "  sys.stderr.write('could not connect; disposable-secret-value\\n'); sys.exit(2)\n"
            " sys.stdout.write(os.environ.get('FAKE_HISTORY', ''))\n"
            " sys.exit(0)\n"
            "diagnostic = pathlib.Path(args[args.index('-f') + 1]).name\n"
            "capture = os.environ.get('FAKE_PSQL_CAPTURE')\n"
            "if capture:\n"
            " with open(capture, 'a', encoding='utf-8') as f: f.write(json.dumps(args) + '\\n')\n"
            "if diagnostic == os.environ.get('FAKE_FAIL_DIAGNOSTIC'):\n"
            " state = os.environ.get('FAKE_SQLSTATE', 'P0001')\n"
            " sys.stderr.write(f'ERROR:  {state}: mocked diagnostic failure\\n')\n"
            " sys.exit(1)\n"
            "sys.exit(0)\n",
            encoding="utf-8",
        )
        self.fake_psql.chmod(0o700)

        self.diagnostics_dir = self.root / "diagnostics"
        self.diagnostics_dir.mkdir()
        for name in DIAGNOSTICS:
            (self.diagnostics_dir / name).write_text("-- mock target only\n", encoding="utf-8")
        self.output = self.root / "integrity-output"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def fake_env(self) -> dict[str, str]:
        return {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
        }

    def run_history(self, *, remote: str = "", connection_error: bool = False):
        env = self.fake_env()
        env["FAKE_HISTORY"] = remote
        env["FAKE_HISTORY_ERROR"] = "1" if connection_error else "0"
        return subprocess.run(
            [sys.executable, str(HISTORY_CHECKER), "--migrations-dir", str(ROOT / "supabase/migrations")],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def run_integrity(self, *, diagnostic: str = "", sqlstate: str = "P0001"):
        env = self.fake_env()
        env.update(
            {
                "FAKE_FAIL_DIAGNOSTIC": diagnostic,
                "FAKE_SQLSTATE": sqlstate,
                "FAKE_PSQL_CAPTURE": str(self.root / "psql-commands.jsonl"),
            }
        )
        return subprocess.run(
            [
                sys.executable,
                str(INTEGRITY_RUNNER),
                "--diagnostics-dir",
                str(self.diagnostics_dir),
                "--output",
                str(self.output),
            ],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_connection_failure_is_generic_and_fails_closed(self) -> None:
        result = self.run_history(connection_error=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("connection or migration-history query failed", result.stderr)
        self.assertNotIn("disposable-secret-value", result.stdout + result.stderr)

        integrity = self.run_integrity(diagnostic=DIAGNOSTICS[0], sqlstate="08006")
        self.assertEqual(integrity.returncode, 2)
        self.assertIn("connection or execution failed", integrity.stderr)
        self.assertNotIn("08006", integrity.stdout + integrity.stderr)

    def test_history_mismatch_is_rejected(self) -> None:
        local = sorted(path.name[:14] for path in (ROOT / "supabase/migrations").glob("*.sql"))
        result = self.run_history(remote="\n".join([*local, "19990101000000"]) + "\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("REMOTE_ONLY: 19990101000000", result.stderr)
        self.assertNotIn("PENDING:", result.stderr)

    def test_reader_and_bootstrap_permission_anomalies_are_mismatches(self) -> None:
        for diagnostic in DIAGNOSTICS[:2]:
            with self.subTest(diagnostic=diagnostic):
                result = self.run_integrity(diagnostic=diagnostic)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.output.read_text(encoding="utf-8"), "result=MISMATCH\n")

    def test_rpc_and_acl_anomalies_are_mismatches(self) -> None:
        for diagnostic in ("verify_s1_08_rpc_integrity.sql", "verify_s1_f01_acl_integrity.sql"):
            with self.subTest(diagnostic=diagnostic):
                result = self.run_integrity(diagnostic=diagnostic)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.output.read_text(encoding="utf-8"), "result=MISMATCH\n")

    def test_privilege_execution_error_is_not_misclassified_as_a_schema_mismatch(self) -> None:
        result = self.run_integrity(diagnostic="verify_production_db_reader.sql", sqlstate="42501")
        self.assertEqual(result.returncode, 2)
        self.assertIn("connection or execution failed", result.stderr)
        self.assertNotIn("42501", result.stdout + result.stderr)

    def test_success_runs_only_the_five_read_only_diagnostic_files(self) -> None:
        result = self.run_integrity()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "result=PASS\n")
        calls = [
            json.loads(line)
            for line in (self.root / "psql-commands.jsonl").read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(len(calls), len(DIAGNOSTICS))
        self.assertEqual([Path(args[args.index("-f") + 1]).name for args in calls], list(DIAGNOSTICS))
        self.assertTrue(all("-c" not in args for args in calls))

    def test_target_configuration_requires_main_session_pooler_reader_and_ssl(self) -> None:
        base = {
            **os.environ,
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_SHA": "a" * 40,
            "PROD_SUPABASE_POOLER_HOST": "aws-1-us-east-2.pooler.supabase.com",
            "PROD_SUPABASE_PROJECT_REF": "projectref123456789012",
            "MIGRATION_READER_PASSWORD": "mock-reader-password",
            "PGHOST": "aws-1-us-east-2.pooler.supabase.com",
            "PGPORT": "5432",
            "PGDATABASE": "postgres",
            "PGUSER": "migration_preflight_login.projectref123456789012",
            "PGSSLMODE": "require",
            "PGCONNECT_TIMEOUT": "10",
        }

        def validate(overrides: dict[str, str] | None = None):
            env = base.copy()
            if overrides:
                env.update(overrides)
            return subprocess.run(
                [sys.executable, str(ENV_VALIDATOR)],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(validate().returncode, 0)
        for overrides in (
            {"GITHUB_REF": "refs/heads/feature"},
            {"PROD_SUPABASE_POOLER_HOST": "db.projectref123456789012.supabase.co", "PGHOST": "db.projectref123456789012.supabase.co"},
            {"PGPORT": "6543"},
            {"PGUSER": "postgres.projectref123456789012"},
            {"PGSSLMODE": "disable"},
            {"MIGRATION_READER_PASSWORD": ""},
            {"PGOPTIONS": "-c default_transaction_read_only=off"},
        ):
            with self.subTest(overrides=overrides):
                result = validate(overrides)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn("mock-reader-password", result.stdout + result.stderr)

    def test_latest_main_sha_check_rejects_stale_run(self) -> None:
        fake_git = self.bin / "git"
        fake_git.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "if sys.argv[1:] != ['ls-remote', 'origin', 'refs/heads/main']: sys.exit(2)\n"
            "print(os.environ.get('FAKE_MAIN_SHA', '') + '\\trefs/heads/main')\n",
            encoding="utf-8",
        )
        fake_git.chmod(0o700)
        env = self.fake_env()
        env["FAKE_MAIN_SHA"] = "a" * 40
        current = subprocess.run(
            [sys.executable, str(LATEST_MAIN), "a" * 40], env=env, capture_output=True, text=True
        )
        stale = subprocess.run(
            [sys.executable, str(LATEST_MAIN), "b" * 40], env=env, capture_output=True, text=True
        )
        self.assertEqual(current.returncode, 0, current.stderr)
        self.assertEqual(stale.returncode, 1)

    def test_workflow_is_manual_main_only_read_only_and_uses_the_reader_environment(self) -> None:
        workflow = (ROOT / ".github/workflows/production-db-check.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("on:\n  workflow_dispatch:", workflow)
        self.assertNotIn("pull_request:", workflow)
        self.assertNotIn("push:", workflow)
        self.assertIn("permissions:\n  contents: read", workflow)
        self.assertIn("refs/heads/main", workflow)
        self.assertIn("scripts/assert-latest-main.py", workflow)
        self.assertIn("name: production-db-check", workflow)
        self.assertIn("PROD_SUPABASE_POOLER_HOST", workflow)
        self.assertIn("PROD_SUPABASE_PROJECT_REF", workflow)
        self.assertIn("secrets.MIGRATION_READER_PASSWORD", workflow)
        self.assertNotIn("MIGRATION_SUPABASE_DB_PASSWORD", workflow)
        self.assertNotIn("supabase db push", workflow)
        identity_step = re.split(r"(?m)^      - name: ", workflow)[1:]
        identity_step = next(
            step for step in identity_step if step.startswith("Verify Prod database-side identity as Reader\n")
        )
        self.assertIn("DB_TARGET: production", identity_step)
        self.assertIn("PGHOST: ${{ vars.PROD_SUPABASE_POOLER_HOST }}", identity_step)
        self.assertIn("PGPORT: \"5432\"", identity_step)
        self.assertIn("PGDATABASE: postgres", identity_step)
        self.assertIn("PGUSER: migration_preflight_login.${{ vars.PROD_SUPABASE_PROJECT_REF }}", identity_step)
        self.assertIn("PGPASSWORD: ${{ secrets.MIGRATION_READER_PASSWORD }}", identity_step)
        self.assertIn("PGSSLMODE: require", identity_step)
        self.assertIn("PGCONNECT_TIMEOUT: \"10\"", identity_step)
        self.assertIn("scripts/verify-db-project-identity.py", identity_step)
        self.assertLess(
            workflow.index("Install PostgreSQL client"),
            workflow.index("Verify Prod database-side identity as Reader"),
        )
        self.assertLess(
            workflow.index("Verify Prod database-side identity as Reader"),
            workflow.index("Require migration history in sync"),
        )
        for diagnostic in DIAGNOSTICS:
            self.assertIn(diagnostic, (ROOT / "scripts/verify-production-db-integrity.py").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
