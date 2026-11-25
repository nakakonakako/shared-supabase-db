"""Tests for the Production Reader-only migration plan."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from run_dev_migration_plan import evaluate_history_result, write_summary

ROOT = Path(__file__).resolve().parents[1]


class ProductionMigrationPlanTests(unittest.TestCase):
    def test_dev_summary_target_remains_the_default(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dev-migration-plan-test-") as directory:
            summary = Path(directory) / "summary.md"
            write_summary(summary, "IN_SYNC", [])
            content = summary.read_text(encoding="utf-8")

        self.assertIn("not part of the Dev history result", content)

    def test_pending_summary_reports_exact_versions_for_production(self) -> None:
        with tempfile.TemporaryDirectory(prefix="production-migration-plan-test-") as directory:
            summary = Path(directory) / "summary.md"
            write_summary(summary, "PENDING", ["20261101011951"], "production")
            content = summary.read_text(encoding="utf-8")

        self.assertIn("Migration history: **PENDING**", content)
        self.assertIn("### Pending migration versions", content)
        self.assertIn("- `20261101011951`", content)
        self.assertIn("not part of the Production history result", content)

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

if __name__ == "__main__":
    unittest.main()
