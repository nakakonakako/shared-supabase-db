"""Mocked tests for the read-only database identity verifier."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS_DIR))
SPEC = importlib.util.spec_from_file_location(
    "verify_db_project_identity",
    SCRIPTS_DIR / "verify-db-project-identity.py",
)
assert SPEC is not None and SPEC.loader is not None
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)


EXPECTED_IDENTITIES = {
    "dev": "shared-supabase-db:target=dev;project_ref=irgahixsuvtopiwmtkku",
    "production": "shared-supabase-db:target=production;project_ref=fsrbddgyysssqzyullrc",
}


class VerifyDatabaseProjectIdentityTests(unittest.TestCase):
    def _run_verifier(
        self,
        *,
        target: str = "dev",
        returncode: int = 0,
        stdout: str | None = None,
        stderr: str = "",
        raise_error: BaseException | None = None,
    ) -> tuple[int, str, str]:
        output = io.StringIO()
        errors = io.StringIO()
        identity = EXPECTED_IDENTITIES[target] if stdout is None else stdout
        result = subprocess.CompletedProcess(args=["psql"], returncode=returncode, stdout=identity, stderr=stderr)
        side_effect: object = raise_error if raise_error is not None else [result]
        with (
            patch.dict(os.environ, {"DB_TARGET": target, "PGPASSWORD": "secret-value"}, clear=True),
            patch.object(verifier.shutil, "which", return_value="/mock/psql"),
            patch.object(verifier.subprocess, "run", side_effect=side_effect) as run_psql,
            contextlib.redirect_stdout(output),
            contextlib.redirect_stderr(errors),
        ):
            code = verifier.main()
            self.assertEqual(run_psql.call_count, 1)
            command = run_psql.call_args.args[0]
            self.assertIn("-c", command)
            self.assertIn("BEGIN TRANSACTION READ ONLY", command[command.index("-c") + 1])
        return code, output.getvalue(), errors.getvalue()

    def test_matching_identity_succeeds_for_dev_and_production(self) -> None:
        for target in EXPECTED_IDENTITIES:
            with self.subTest(target=target):
                code, output, errors = self._run_verifier(target=target)
                self.assertEqual(code, 0)
                self.assertIn(f"{target} server-side marker matches", output)
                self.assertEqual(errors, "")

    def test_mismatched_identity_fails_closed(self) -> None:
        code, output, errors = self._run_verifier(stdout="some-other-marker")
        self.assertEqual(code, 1)
        self.assertEqual(output, "")
        self.assertIn("database marker is missing or mismatched", errors)

    def test_known_psql_errors_are_classified_without_logging_diagnostics(self) -> None:
        cases = (
            ("FATAL: password authentication failed for user postgres.secret-user", 2, "authentication"),
            ('FATAL: role "postgres.secret-user" does not exist', 2, "authentication"),
            ("could not translate host name \"secret-host\": Name or service not known", 2, "network / DNS"),
            ("connection timed out", 2, "connection_timeout"),
            ("could not connect to server: Connection refused", 2, "connection_refused"),
            ("SSL error: certificate verify failed for secret-host", 2, "SSL / TLS"),
            ("FATAL: MaxClientsInSessionMode: max clients reached", 2, "pooler / connection_limit"),
            ("ERROR: permission denied for database secret-db", 3, "SQL execution error"),
            ("unrecognized diagnostic containing secret-value secret-host secret-user", 2, "unknown"),
        )
        for diagnostic, returncode, category in cases:
            with self.subTest(category=category):
                code, output, errors = self._run_verifier(returncode=returncode, stdout="", stderr=diagnostic)
                self.assertEqual(code, 2)
                self.assertEqual(output, "")
                self.assertIn(f"({category})", errors)
                self.assertNotIn(diagnostic, errors)
                for sensitive in ("secret-value", "secret-host", "secret-user", "secret-db"):
                    self.assertNotIn(sensitive, output + errors)

    def test_timeout_and_unknown_execution_errors_do_not_leak_exception_text(self) -> None:
        cases = (
            (subprocess.TimeoutExpired("psql", 20, stderr="secret-value secret-host"), "unknown"),
            (OSError("failed to launch psql using secret-value at secret-host"), "unknown"),
        )
        for error, category in cases:
            with self.subTest(category=category):
                code, output, errors = self._run_verifier(raise_error=error)
                self.assertEqual(code, 2)
                self.assertEqual(output, "")
                self.assertIn(f"({category})", errors)
                for sensitive in ("secret-value", "secret-host"):
                    self.assertNotIn(sensitive, output + errors)

    def test_known_connection_failure_takes_precedence_over_sql_failure(self) -> None:
        self.assertEqual(
            verifier.classify_psql_failure(3, "ERROR: connection refused while contacting pooler"),
            "connection_refused",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
