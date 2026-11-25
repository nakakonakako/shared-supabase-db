#!/usr/bin/env python3
"""Tests for the Reader-only Dev migration plan result handling."""

from __future__ import annotations

import unittest
from pathlib import Path

from run_dev_migration_plan import evaluate_history_result

ROOT = Path(__file__).resolve().parents[1]


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

if __name__ == "__main__":
    unittest.main()
