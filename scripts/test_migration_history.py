#!/usr/bin/env python3
"""Unit tests for the fail-closed migration history and immutability checker."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("check-migration-history.py")


class MigrationHistoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="migration-history-test-")
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.migrations = self.repo / "supabase" / "migrations"
        self.migrations.mkdir(parents=True)
        self._git("init", "-b", "main")
        self._git("config", "user.name", "Migration test")
        self._git("config", "user.email", "migration-test@example.invalid")
        (self.migrations / "20260101000000_initial.sql").write_text("select 1;\n")
        self._git("add", ".")
        self._git("commit", "-m", "fixture")
        self.base = self._git("rev-parse", "HEAD").stdout.strip()
        self.remote = self.root / "remote.txt"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _git(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            check=True,
            capture_output=True,
            text=True,
        )

    def _check(self, remote: str, *, base: bool = False, env: dict[str, str] | None = None):
        self.remote.write_text(remote)
        command = [
            "python3",
            str(SCRIPT),
            "--repo",
            str(self.repo),
            "--migrations-dir",
            str(self.migrations),
            "--remote-versions-file",
            str(self.remote),
        ]
        if base:
            command.extend(["--base-ref", self.base])
        merged_env = os.environ.copy()
        if env:
            merged_env.update(env)
        return subprocess.run(command, capture_output=True, text=True, env=merged_env)

    def test_in_sync_history_passes(self) -> None:
        result = self._check("20260101000000\n", base=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("IN_SYNC", result.stdout)

    def test_local_only_is_pending_and_fails_closed(self) -> None:
        result = self._check("")
        self.assertEqual(result.returncode, 1)
        self.assertIn("PENDING: 20260101000000", result.stderr)

    def test_remote_only_fails_closed(self) -> None:
        result = self._check("20250101000000\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("REMOTE_ONLY: 20250101000000", result.stderr)

    def test_malformed_remote_history_fails_closed(self) -> None:
        result = self._check("not-a-version\n")
        self.assertEqual(result.returncode, 2)
        self.assertIn("malformed version", result.stderr)

    def test_duplicate_local_version_fails_closed(self) -> None:
        (self.migrations / "20260101000000_duplicate.sql").write_text("select 2;\n")
        result = self._check("20260101000000\n")
        self.assertEqual(result.returncode, 2)
        self.assertIn("duplicate local", result.stderr)

    def test_database_connection_error_is_generic(self) -> None:
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        psql = fake_bin / "psql"
        psql.write_text("#!/bin/sh\necho 'secret-test-password invalid' >&2\nexit 2\n")
        psql.chmod(0o700)
        result = subprocess.run(
            [
                "python3",
                str(SCRIPT),
                "--repo",
                str(self.repo),
                "--migrations-dir",
                str(self.migrations),
            ],
            capture_output=True,
            text=True,
            env={**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"},
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("connection or migration-history query failed", result.stderr)
        self.assertNotIn("secret-test-password", result.stdout + result.stderr)

    def test_changed_or_deleted_migration_is_rejected(self) -> None:
        migration = self.migrations / "20260101000000_initial.sql"
        migration.write_text("select 99;\n")
        result = self._check("20260101000000\n", base=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("immutable", result.stderr)

        migration.unlink()
        result = self._check("20260101000000\n", base=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("immutable", result.stderr)

    def test_new_migration_is_allowed(self) -> None:
        (self.migrations / "20260201000000_added.sql").write_text("select 2;\n")
        result = self._check("20260101000000\n", base=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("PENDING: 20260201000000", result.stderr)

    def test_existing_verifiers_do_not_require_postgres_identity_and_keep_singleton_check(self) -> None:
        diagnostics = SCRIPT.parent.parent / "supabase" / "diagnostics"
        f01 = (diagnostics / "verify_s1_f01_acl_integrity.sql").read_text()
        ai_quota = (diagnostics / "verify_s1_06_ai_quota_integrity.sql").read_text()
        self.assertNotIn("current_user <> 'postgres'", f01)
        self.assertNotIn("member.rolname = current_user", ai_quota)
        self.assertIn("FROM ai_quota.settings\n      WHERE id = 1", ai_quota)
        self.assertNotIn("SELECT emergency_stop", ai_quota)

        reader_audit = (
            diagnostics / "verify_migration_preflight_reader.sql"
        ).read_text()
        self.assertIn("has_column_privilege", reader_audit)
        self.assertIn("a.attname <> 'id'", reader_audit)

    def test_reader_migration_preserves_the_bootstrap_admin_membership(self) -> None:
        migration = (
            SCRIPT.parent.parent
            / "supabase"
            / "migrations"
            / "20261027150000_migration_preflight_reader.sql"
        ).read_text()
        self.assertIn("m.admin_option", migration)
        self.assertIn("with set true, inherit false", migration.lower())
        self.assertIn("REVOKE ai_quota_owner FROM %I GRANTED BY %I", migration)
        self.assertNotIn("revoke ai_quota_owner from current_user;", migration.lower())
        self.assertIn("ADMIN-only ai_quota_owner membership was not preserved", migration)


if __name__ == "__main__":
    unittest.main(verbosity=2)
