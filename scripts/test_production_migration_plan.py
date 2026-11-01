"""Tests for the Production Reader-only migration plan."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from run_dev_migration_plan import evaluate_history_result, write_summary

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/production-migration-plan.yml"
CHECKER = ROOT / "scripts/check-migration-history.py"


class ProductionMigrationPlanTests(unittest.TestCase):
    def test_dev_summary_target_remains_the_default(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dev-migration-plan-test-") as directory:
            summary = Path(directory) / "summary.md"
            write_summary(summary, "IN_SYNC", [])
            content = summary.read_text(encoding="utf-8")

        self.assertIn("separate Dev consumer contract check", content)

    def test_pending_summary_reports_exact_versions_for_production(self) -> None:
        with tempfile.TemporaryDirectory(prefix="production-migration-plan-test-") as directory:
            summary = Path(directory) / "summary.md"
            write_summary(summary, "PENDING", ["20261101011951"], "production")
            content = summary.read_text(encoding="utf-8")

        self.assertIn("Migration history: **PENDING**", content)
        self.assertIn("### Pending migration versions", content)
        self.assertIn("- `20261101011951`", content)
        self.assertIn("Production consumer contract check", content)

    def test_reader_history_evaluation_only_accepts_in_sync_or_valid_pending(self) -> None:
        self.assertEqual(
            evaluate_history_result(0, "state=IN_SYNC\n", "migration preflight: IN_SYNC (15 versions)"),
            ("IN_SYNC", [], True),
        )
        self.assertEqual(
            evaluate_history_result(
                1,
                "state=PENDING\n",
                "migration preflight: PENDING: 20261101011951\n",
            ),
            ("PENDING", ["20261101011951"], True),
        )
        for result in (
            (1, "state=REMOTE_ONLY\n", "migration preflight: REMOTE_ONLY: 20261101011951"),
            (2, "state=ERROR\n", "migration preflight: ERROR: history query failed"),
            (0, "state=PENDING\n", "migration preflight: PENDING: 20261101011951"),
            (1, "state=PENDING\n", "migration preflight: PENDING: malformed"),
        ):
            with self.subTest(result=result):
                self.assertEqual(evaluate_history_result(*result)[2], False)

    def test_workflow_is_manual_main_only_production_reader_and_apply_free(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", source)
        self.assertIn('GITHUB_REF" != refs/heads/main', source)
        self.assertIn("permissions:\n  contents: read", source)
        self.assertIn("name: production-db-check", source)
        self.assertIn("secrets.MIGRATION_READER_PASSWORD", source)
        self.assertIn("DB_TARGET: production", source)
        self.assertIn("DB_CONNECTION_ROLE: reader", source)
        self.assertIn("scripts/validate-writer-db-env.py", source)
        self.assertIn("scripts/check-migrations.py", source)
        self.assertIn("verify_production_db_reader.sql", source)
        self.assertIn("verify_migration_preflight_reader.sql", source)
        self.assertIn("verify_migration_reader_bootstrap.sql", source)
        self.assertIn("scripts/verify-db-project-identity.py", source)
        self.assertIn("scripts/run_dev_migration_plan.py", source)
        self.assertIn("--target production", source)
        self.assertNotIn("production-db-apply", source)
        self.assertNotIn("MIGRATION_SUPABASE_DB_PASSWORD", source)
        self.assertNotIn("PROD_DB_WRITER_ENABLED", source)
        self.assertNotIn("supabase db push", source)
        self.assertIn("BEGIN TRANSACTION READ ONLY", CHECKER.read_text(encoding="utf-8"))
        self.assertLess(
            source.index("Validate migration immutability"),
            source.index("Verify minimum Reader privileges"),
        )
        self.assertLess(
            source.index("validate-writer-db-env.py"),
            source.index("Verify minimum Reader privileges"),
        )
        self.assertLess(
            source.index("Verify Production DB identity"),
            source.index("Classify shared Production migration history"),
        )


if __name__ == "__main__":
    unittest.main()
