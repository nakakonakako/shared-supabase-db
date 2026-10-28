"""Tests for Dev target separation and fail-closed configuration validation."""

from __future__ import annotations

import os
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts/validate-dev-db-contract-env.py"
WORKFLOW = ROOT / ".github/workflows/dev-consumer-db-contract-check.yml"


class DevDbContractCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.password = "dev-only-mock-reader-password"
        self.env = {
            "PATH": os.environ.get("PATH", ""),
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_SHA": "a" * 40,
            "DEV_SUPABASE_POOLER_HOST": "aws-1-us-east-2.pooler.supabase.com",
            "DEV_SUPABASE_PROJECT_REF": "devprojectref123456789",
            "DEV_MIGRATION_READER_PASSWORD": self.password,
            "PGHOST": "aws-1-us-east-2.pooler.supabase.com",
            "PGPORT": "5432",
            "PGDATABASE": "postgres",
            "PGUSER": "migration_preflight_login.devprojectref123456789",
            "PGSSLMODE": "require",
            "PGCONNECT_TIMEOUT": "10",
        }

    def validate(self, overrides: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        env = self.env.copy()
        if overrides:
            env.update(overrides)
        return subprocess.run(
            [sys.executable, str(VALIDATOR)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_valid_dedicated_dev_target_passes_without_echoing_credentials(self) -> None:
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("target configuration valid", result.stdout)
        self.assertNotIn(self.password, result.stdout + result.stderr)
        self.assertNotIn(self.env["DEV_SUPABASE_PROJECT_REF"], result.stdout + result.stderr)

    def test_missing_or_mismatched_dev_configuration_fails_closed(self) -> None:
        for overrides in (
            {"DEV_SUPABASE_POOLER_HOST": ""},
            {"DEV_SUPABASE_PROJECT_REF": ""},
            {"DEV_MIGRATION_READER_PASSWORD": ""},
            {"PGHOST": "aws-2-us-east-2.pooler.supabase.com"},
            {"PGUSER": "migration_preflight_login.prodprojectref123456789"},
            {"PGPORT": "6543"},
            {"PGSSLMODE": "disable"},
            {"GITHUB_REF": "refs/heads/feature"},
            {"GITHUB_SHA": "not-a-full-sha"},
            {"PGOPTIONS": "-c default_transaction_read_only=off"},
        ):
            with self.subTest(overrides=overrides):
                result = self.validate(overrides)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn(self.password, result.stdout + result.stderr)

    def test_production_configuration_names_are_rejected(self) -> None:
        for name, value in (
            ("PROD_SUPABASE_POOLER_HOST", "aws-1-us-east-2.pooler.supabase.com"),
            ("PROD_SUPABASE_PROJECT_REF", "prodprojectref123456789"),
            ("MIGRATION_READER_PASSWORD", "prod-only-mock-reader-password"),
        ):
            with self.subTest(name=name):
                result = self.validate({name: value})
                self.assertEqual(result.returncode, 2)
                self.assertNotIn(value, result.stdout + result.stderr)

    def test_workflow_is_dev_only_main_only_and_validates_before_credentials(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("on:\n  workflow_dispatch:", workflow)
        self.assertNotIn("pull_request:", workflow)
        self.assertNotIn("push:", workflow)
        self.assertIn("permissions:\n  contents: read", workflow)
        self.assertIn("name: development-db-check", workflow)
        self.assertIn("scripts/assert-latest-main.py", workflow)
        self.assertIn("scripts/validate-dev-db-contract-env.py", workflow)
        self.assertIn("DEV_SUPABASE_POOLER_HOST", workflow)
        self.assertIn("DEV_SUPABASE_PROJECT_REF", workflow)
        self.assertIn("secrets.DEV_MIGRATION_READER_PASSWORD", workflow)
        self.assertNotIn("PROD_SUPABASE_", workflow)
        self.assertNotIn("secrets.MIGRATION_READER_PASSWORD", workflow)
        self.assertNotIn("contents: write", workflow)
        self.assertLess(
            workflow.index("Fetch and validate both pinned contracts before DB access"),
            workflow.index("secrets.DEV_MIGRATION_READER_PASSWORD"),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
