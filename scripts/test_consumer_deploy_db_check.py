"""Fail-closed tests for the app deployment Reader gate (no hosted DB access)."""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_consumer_deploy_db_check as gate


APP_SHA = "a" * 40
SHARED_SHA = "b" * 40


def valid_env() -> dict[str, str]:
    return {
        "INPUT_APP_ID": "receipt-manager",
        "INPUT_APP_COMMIT_SHA": APP_SHA,
        "GITHUB_REPOSITORY": "nakakonakako/receipt-manager",
        "GITHUB_REF": "refs/heads/main",
        "GITHUB_SHA": APP_SHA,
        "DB_TARGET": "production",
        "DB_ENVIRONMENT": "production-db-check",
        "DB_CONNECTION_ROLE": "reader",
        "DB_POOLER_HOST": "aws-1-us-east-1.pooler.supabase.com",
        "DB_PROJECT_REF": "fsrbddgyysssqzyullrc",
        "PGHOST": "aws-1-us-east-1.pooler.supabase.com",
        "PGPORT": "5432",
        "PGDATABASE": "postgres",
        "PGUSER": "migration_preflight_login.fsrbddgyysssqzyullrc",
        "PGPASSWORD": "test-only-not-a-real-secret",
        "PGSSLMODE": "require",
        "PGCONNECT_TIMEOUT": "10",
    }


class ConsumerDeployGateTests(unittest.TestCase):
    def invoke(self, state: str = "IN_SYNC", *, fail_label: str = "") -> tuple[int, list[list[str]]]:
        env = valid_env()
        commands: list[list[str]] = []

        def fake_run(command: list[str], *, cwd=None, env=None, timeout=90):
            commands.append(command)
            if fail_label and fail_label in " ".join(command):
                return gate.subprocess.CompletedProcess(command, 2, "", "do not expose this")
            if "check-migration-history.py" in " ".join(command) and env:
                Path(env["GITHUB_OUTPUT"]).write_text(f"state={state}\n", encoding="utf-8")
                return gate.subprocess.CompletedProcess(command, 0 if state == "IN_SYNC" else 1, "", "")
            if "verify-consumer-db-contracts.py" in " ".join(command) and "--validate-only" in command:
                return gate.subprocess.CompletedProcess(command, 0, "receipt-manager: CONTRACT FORMAT PASS", "")
            if "verify-consumer-db-contracts.py" in " ".join(command):
                return gate.subprocess.CompletedProcess(command, 0, "receipt-manager: STATIC PASS (3 catalog assertions)", "")
            return gate.subprocess.CompletedProcess(command, 0, "PASS", "")

        with patch.dict(os.environ, env, clear=True), patch.object(gate, "remote_main", side_effect=[APP_SHA, SHARED_SHA, SHARED_SHA, APP_SHA]), patch.object(gate, "run", side_effect=fake_run):
            result = gate.main()
        return result, commands

    def test_happy_path_requires_inventory_identity_history_and_target_contract(self) -> None:
        result, commands = self.invoke()
        self.assertEqual(result, 0)
        contract_commands = [command for command in commands if "verify-consumer-db-contracts.py" in " ".join(command)]
        self.assertEqual(len(contract_commands), 2)
        self.assertTrue(all("--app-id" in command and "receipt-manager" in command and "--app-commit" in command and APP_SHA in command for command in contract_commands))
        self.assertLess(commands.index(contract_commands[0]), next(i for i, c in enumerate(commands) if "verify-db-project-identity.py" in " ".join(c)))

    def test_contract_format_failure_stops_before_database_commands(self) -> None:
        result, commands = self.invoke(fail_label="--validate-only")
        self.assertEqual(result, 2)
        self.assertFalse(any("psql" in " ".join(command) or "verify-db-project-identity.py" in " ".join(command) for command in commands))

    def test_reader_connection_failure_is_fail_closed_before_history_or_contract_catalog(self) -> None:
        result, commands = self.invoke(fail_label="verify-db-project-identity.py")
        self.assertEqual(result, 2)
        self.assertFalse(any("check-migration-history.py" in " ".join(command) for command in commands))
        self.assertFalse(any("verify-consumer-db-contracts.py" in " ".join(command) and "--validate-only" not in command for command in commands))

    def test_non_in_sync_states_fail_closed(self) -> None:
        for state in ("PENDING", "REMOTE_ONLY", "ERROR"):
            with self.subTest(state=state):
                result, commands = self.invoke(state)
                self.assertEqual(result, 2)
                self.assertFalse(any("verify-consumer-db-contracts.py" in " ".join(command) and "--validate-only" not in command for command in commands))

    def test_invalid_caller_and_missing_reader_credentials_fail_before_commands(self) -> None:
        env = valid_env()
        env["GITHUB_REF"] = "refs/pull/5/merge"
        with patch.dict(os.environ, env, clear=True), patch.object(gate, "run") as run_mock:
            self.assertEqual(gate.main(), 2)
        run_mock.assert_not_called()

        env = valid_env()
        env["PGPASSWORD"] = ""
        commands: list[list[str]] = []
        def fail_reader_config(command, *, cwd=None, env=None, timeout=90):
            commands.append(command)
            if "validate-writer-db-env.py" in " ".join(command):
                return gate.subprocess.CompletedProcess(command, 2, "", "password hidden")
            if "check-migration-history.py" in " ".join(command):
                Path(env["GITHUB_OUTPUT"]).write_text("state=IN_SYNC\n", encoding="utf-8")
            return gate.subprocess.CompletedProcess(command, 0, "ok", "")
        with patch.dict(os.environ, env, clear=True), patch.object(gate, "remote_main", side_effect=[APP_SHA, SHARED_SHA]), patch.object(gate, "run", side_effect=fail_reader_config):
            self.assertEqual(gate.main(), 2)
        self.assertFalse(any("verify-db-project-identity.py" in " ".join(command) for command in commands))


if __name__ == "__main__":
    unittest.main()
