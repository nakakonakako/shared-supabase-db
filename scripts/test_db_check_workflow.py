"""Guards for the single manual, Reader-only DB check workflow."""
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/db-check.yml"
VALIDATOR = ROOT / "scripts/validate-writer-db-env.py"
PLAN_RUNNER = ROOT / "scripts/run_dev_migration_plan.py"
READER_SECRETS = ("secrets.DEV_MIGRATION_READER_PASSWORD", "secrets.MIGRATION_READER_PASSWORD")
HOST = "aws-1-ap-northeast-1.pooler.supabase.com"
REFS = {"dev": "irgahixsuvtopiwmtkku", "production": "fsrbddgyysssqzyullrc"}


def steps(source: str) -> dict[str, str]:
    check_job = source.split("\n  check:\n", 1)[1]
    return {block.split("\n", 1)[0]: block for block in re.split(r"(?m)^      - name: ", check_job)[1:]}


class DbCheckWorkflowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = WORKFLOW.read_text(encoding="utf-8")

    def test_manual_main_only_and_read_only(self) -> None:
        for required in ("workflow_dispatch:", "options: [dev, production]",
                         "permissions:\n  contents: read", 'GITHUB_REF" != refs/heads/main',
                         "needs: require-latest-main", "scripts/assert-latest-main.py"):
            self.assertIn(required, self.source)
        for forbidden in ("pull_request:", "push:", "contents: write", "db-apply", "SUPABASE_DB_PASSWORD",
                          "AI_QUOTA_ADMIN_PASSWORD", "AI_QUOTA_BACKEND_PASSWORD", "supabase db push",
                          "supabase/setup-cli", "apply-pending-migrations"):
            self.assertNotIn(forbidden, self.source)

    def test_target_selects_only_its_reader_environment_and_credentials(self) -> None:
        self.assertIn("name: ${{ inputs.target == 'dev' && 'development-db-check' || 'production-db-check' }}", self.source)
        self.assertIn("DB_CONNECTION_ROLE: reader", self.source)
        self.assertIn("PGUSER: migration_preflight_login.", self.source)
        self.assertEqual(set(re.findall(r"secrets\.[A-Z_]+", self.source)), set(READER_SECRETS))
        expression = ("PGPASSWORD: ${{ (inputs.target == 'dev' && secrets.DEV_MIGRATION_READER_PASSWORD) || "
                      "(inputs.target == 'production' && secrets.MIGRATION_READER_PASSWORD) || '' }}")
        self.assertEqual(self.source.count("PGPASSWORD:"), self.source.count(expression))

    def test_credentials_are_only_given_to_database_steps_after_offline_checks(self) -> None:
        job_env = self.source.split("\n  check:\n", 1)[1].split("\n    steps:\n", 1)[0]
        self.assertNotIn("PGPASSWORD", job_env)
        blocks = steps(self.source)
        order = list(blocks)
        expected = [
            "Validate migration immutability and checksums before DB access",
            "Fetch and validate both pinned contracts before DB access",
            "Verify PostgreSQL client",
            "Validate the dedicated Reader target",
            "Verify minimum Reader privileges",
            "Verify database-side project identity as Reader",
            "Classify shared migration history without applying migrations",
            "Verify both pinned app contracts as the read-only Reader",
            "Verify Production integrity",
            "Verify Dev AI quota integrity",
        ]
        self.assertEqual([name for name in order if name in expected], expected)
        for name in expected[:3]:
            self.assertNotIn("PGPASSWORD", blocks[name])
        for name in expected[3:]:
            self.assertIn("PGPASSWORD", blocks[name])
        privileges = blocks["Verify minimum Reader privileges"]
        for diagnostic in ("verify_dev_db_contract_reader.sql", "verify_production_db_reader.sql",
                           "verify_migration_preflight_reader.sql", "verify_migration_reader_bootstrap.sql"):
            self.assertIn(diagnostic, privileges)

    def test_integrity_runs_only_for_the_selected_target_when_in_sync(self) -> None:
        blocks = steps(self.source)
        production = blocks["Verify Production integrity"]
        self.assertIn("if: inputs.target == 'production' && steps.history.outputs.state == 'IN_SYNC'", production)
        self.assertIn("scripts/verify-production-db-integrity.py", production)
        self.assertIn("grep -Fxq 'result=PASS'", production)
        dev = blocks["Verify Dev AI quota integrity"]
        self.assertIn("if: inputs.target == 'dev' && steps.history.outputs.state == 'IN_SYNC'", dev)
        self.assertIn("verify_s1_06_ai_quota_integrity.sql", dev)
        self.assertIn("verify_ai_quota_admin_integrity.sql", dev)
        history = blocks["Classify shared migration history without applying migrations"]
        self.assertIn("id: history", history)
        self.assertIn('--target "$DB_TARGET"', history)
        self.assertIn('--state-output "$GITHUB_OUTPUT"', history)
        self.assertIn("Integrity checks were skipped", self.source)

    def test_reader_target_validation_is_pinned_per_target(self) -> None:
        def run(target: str, **overrides: str) -> int:
            ref = REFS[target]
            environment = "development-db-check" if target == "dev" else "production-db-check"
            env = {"PATH": os.environ["PATH"], "DB_TARGET": target, "DB_ENVIRONMENT": environment,
                   "DB_POOLER_HOST": HOST, "DB_PROJECT_REF": ref, "DB_CONNECTION_ROLE": "reader",
                   "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": "a" * 40, "PGHOST": HOST, "PGPORT": "5432",
                   "PGDATABASE": "postgres", "PGUSER": f"migration_preflight_login.{ref}",
                   "PGSSLMODE": "require", "PGCONNECT_TIMEOUT": "10", "PGPASSWORD": "private-test-secret", **overrides}
            result = subprocess.run([sys.executable, str(VALIDATOR)], env=env, capture_output=True, text=True)
            self.assertNotIn("private-test-secret", result.stdout + result.stderr)
            return result.returncode

        for target, other in (("dev", "production"), ("production", "dev")):
            self.assertEqual(run(target), 0)
            wrong = REFS[other]
            for overrides in ({"DB_PROJECT_REF": wrong, "PGUSER": f"migration_preflight_login.{wrong}"},
                              {"DB_ENVIRONMENT": "production-db-apply"}, {"PGUSER": f"postgres.{REFS[target]}"},
                              {"GITHUB_REF": "refs/heads/other"}, {"PGPASSWORD": ""}, {"PGSSLMODE": "disable"},
                              {"PGHOSTADDR": "127.0.0.1"}):
                with self.subTest(target=target, overrides=overrides):
                    self.assertNotEqual(run(target, **overrides), 0)

    def test_history_state_is_published_for_later_steps(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "github-output"
            result = subprocess.run(
                [sys.executable, str(PLAN_RUNNER), "--migrations-dir", str(Path(directory) / "missing"),
                 "--repo", directory, "--state-output", str(output)],
                env={"PATH": os.environ["PATH"]}, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(output.read_text(encoding="utf-8"), "state=ERROR\n")


if __name__ == "__main__":
    unittest.main()
