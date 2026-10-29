#!/usr/bin/env python3
"""Tests for the Reader-only Dev migration plan result handling."""

from __future__ import annotations

import unittest
from pathlib import Path

from run_dev_migration_plan import evaluate_history_result

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/dev-migration-plan.yml"
PLAN_RUNNER = ROOT / "scripts/run_dev_migration_plan.py"


class DevMigrationPlanTests(unittest.TestCase):
    def test_in_sync_is_success_only_with_exit_code_zero(self) -> None:
        self.assertEqual(
            evaluate_history_result(0, "state=IN_SYNC\n", "migration preflight: IN_SYNC (2 versions)"),
            ("IN_SYNC", [], True),
        )
        self.assertEqual(evaluate_history_result(1, "state=IN_SYNC\n", ""), ("ERROR", [], False))

    def test_pending_exit_code_one_is_a_successful_plan_with_versions(self) -> None:
        output = "migration preflight: PENDING: 20260101000000,20260102000000\n"
        self.assertEqual(
            evaluate_history_result(1, "state=PENDING\n", output),
            ("PENDING", ["20260101000000", "20260102000000"], True),
        )
        self.assertEqual(evaluate_history_result(0, "state=PENDING\n", output), ("ERROR", [], False))

    def test_remote_only_and_error_never_become_success(self) -> None:
        self.assertEqual(
            evaluate_history_result(1, "state=REMOTE_ONLY\n", "migration preflight: REMOTE_ONLY: 20260102000000"),
            ("REMOTE_ONLY", [], False),
        )
        self.assertEqual(
            evaluate_history_result(2, "state=ERROR\n", "migration preflight: ERROR: query failed"),
            ("ERROR", [], False),
        )

    def test_missing_malformed_or_inconsistent_result_fails_closed(self) -> None:
        invalid = (
            (1, "", "migration preflight: PENDING: 20260101000000"),
            (1, "state=PENDING\nstate=IN_SYNC\n", "migration preflight: PENDING: 20260101000000"),
            (1, "state=PENDING\n", "migration preflight: PENDING: malformed"),
            (1, "state=PENDING\n", ""),
            (1, "state=REMOTE_ONLY\n", "migration preflight: PENDING: 20260101000000"),
            (2, "state=REMOTE_ONLY\n", "migration preflight: REMOTE_ONLY: 20260102000000"),
            (0, "state=REMOTE_ONLY\n", ""),
            (0, "state=UNKNOWN\n", ""),
        )
        for result in invalid:
            with self.subTest(result=result):
                self.assertEqual(evaluate_history_result(*result), ("ERROR", [], False))

    def test_workflow_is_manual_main_only_reader_only_and_read_only(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", source)
        self.assertIn('GITHUB_REF" != refs/heads/main', source)
        self.assertIn("permissions:\n  contents: read", source)
        self.assertIn("name: development-db-check", source)
        self.assertIn("secrets.DEV_MIGRATION_READER_PASSWORD", source)
        self.assertNotIn("DEV_MIGRATION_SUPABASE_DB_PASSWORD", source)
        self.assertNotIn("supabase db push", source)
        self.assertIn("BEGIN TRANSACTION READ ONLY", (ROOT / "scripts/check-migration-history.py").read_text())
        self.assertIn("check-migrations.py", source)
        self.assertIn("verify-db-project-identity.py", source)
        self.assertIn("verify_migration_preflight_reader.sql", source)
        self.assertIn("run_dev_migration_plan.py", source)
        self.assertLess(source.index("Validate migration immutability"), source.index("Verify Dev DB identity"))
        self.assertLess(source.index("Verify Dev DB identity"), source.index("Classify shared migration history"))
        self.assertIn("DB contract compatibility: not checked", PLAN_RUNNER.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
