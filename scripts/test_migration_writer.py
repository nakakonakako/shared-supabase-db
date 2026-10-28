"""Tests for Writer target validation, migration state handling, and workflow guards."""

from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WRITER_ENV = ROOT / "scripts/validate-writer-db-env.py"
APPLY = ROOT / "scripts/apply-pending-migrations.py"
ENV_CHECK = ROOT / "scripts/check-writer-environment.py"
URL_WRITER = ROOT / "scripts/write-supabase-db-url.py"
WORKFLOW_RESULT = ROOT / "scripts/evaluate-db-migration-workflow.py"
IDENTITY_CHECK = ROOT / "scripts/verify-db-project-identity.py"
DEV_WRITER_GATE = ROOT / "scripts/require-dev-writer-enabled.py"


class MigrationWriterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="migration-writer-test-")
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.repo = self.root / "repo"
        self.migrations = self.repo / "supabase/migrations"
        self.migrations.mkdir(parents=True)
        self.migration = self.migrations / "20260101000000_fixture.sql"
        self.migration.write_text("SELECT 1;\n", encoding="utf-8")
        digest = hashlib.sha256(self.migration.read_bytes()).hexdigest()
        (self.migrations / "SHA256SUMS").write_text(
            f"{digest}  supabase/migrations/{self.migration.name}\n", encoding="utf-8"
        )
        self._git("init", "-b", "main")
        self._git("config", "user.name", "Migration Writer Test")
        self._git("config", "user.email", "migration-writer-test@example.invalid")
        self._git("add", ".")
        self._git("commit", "-m", "fixture")
        self.base_ref = self._git("rev-parse", "HEAD").stdout.strip()
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '')}",
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _git(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            check=True,
            capture_output=True,
            text=True,
        )

    def _validate_writer(self, overrides: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        env = {
            **self.env,
            "DB_TARGET": "production",
            "DB_ENVIRONMENT": "production-db-apply",
            "DB_POOLER_HOST": "aws-1-us-east-2.pooler.supabase.com",
            "DB_PROJECT_REF": "fsrbddgyysssqzyullrc",
            "DB_CONNECTION_ROLE": "writer",
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_SHA": "a" * 40,
            "PGHOST": "aws-1-us-east-2.pooler.supabase.com",
            "PGPORT": "5432",
            "PGDATABASE": "postgres",
            "PGUSER": "postgres.fsrbddgyysssqzyullrc",
            "PGPASSWORD": "writer-secret-fixture",
            "PGSSLMODE": "require",
            "PGCONNECT_TIMEOUT": "10",
        }
        if overrides:
            env.update(overrides)
        return subprocess.run(
            [sys.executable, str(WRITER_ENV)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def _run_apply(
        self,
        remote: str,
        cli: Path,
        *,
        secret: str = "do-not-log-secret",
        cli_capture: Path | None = None,
    ):
        fake_psql = self.bin / "psql"
        fake_psql.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "if '-c' in sys.argv:\n"
            " if os.environ.get('FAKE_PSQL_ERROR') == '1':\n"
            "  sys.stderr.write('connection failed " + secret + "\\n'); sys.exit(2)\n"
            " sys.stdout.write(os.environ.get('FAKE_HISTORY', ''))\n"
            " sys.exit(0)\n"
            "sys.exit(0)\n",
            encoding="utf-8",
        )
        fake_psql.chmod(0o700)
        env = {
            **self.env,
            "FAKE_HISTORY": remote,
            "SUPABASE_DB_URL": "postgresql://" + "writer" + ":" + secret + "@localhost/postgres",
        }
        if cli_capture:
            env["FAKE_CLI_CAPTURE"] = str(cli_capture)
        return subprocess.run(
            [
                sys.executable,
                str(APPLY),
                "--repo",
                str(self.repo),
                "--migrations-dir",
                str(self.migrations),
                "--workdir",
                str(self.repo),
                "--base-ref",
                self.base_ref,
                "--psql",
                str(fake_psql),
                "--supabase",
                str(cli),
            ],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_writer_target_requires_exact_environment_and_tls_settings(self) -> None:
        passed = self._validate_writer()
        self.assertEqual(passed.returncode, 0, passed.stderr)
        self.assertNotIn("writer-secret-fixture", passed.stdout + passed.stderr)
        for overrides in (
            {"DB_TARGET": "dev"},
            {"DB_ENVIRONMENT": "production-db-check"},
            {"PGHOST": "aws-1-us-east-2.pooler.supabase.com.attacker.invalid"},
            {"PGUSER": "migration_preflight_login.fsrbddgyysssqzyullrc"},
            {"PGSSLMODE": "disable"},
            {"GITHUB_REF": "refs/heads/feature"},
            {"PGOPTIONS": "-c default_transaction_read_only=off"},
            {"PGPASSWORD": ""},
        ):
            with self.subTest(overrides=overrides):
                result = self._validate_writer(overrides)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn("writer-secret-fixture", result.stdout + result.stderr)

        dev = self._validate_writer(
            {
                "DB_TARGET": "dev",
                "DB_ENVIRONMENT": "development-db-apply",
                "DB_POOLER_HOST": "aws-2-us-east-1.pooler.supabase.com",
                "DB_PROJECT_REF": "irgahixsuvtopiwmtkku",
                "PGHOST": "aws-2-us-east-1.pooler.supabase.com",
                "PGUSER": "postgres.irgahixsuvtopiwmtkku",
            }
        )
        self.assertEqual(dev.returncode, 0, dev.stderr)
        wrong_dev_project = self._validate_writer(
            {
                "DB_TARGET": "dev",
                "DB_ENVIRONMENT": "development-db-apply",
                "DB_POOLER_HOST": "aws-1-ap-northeast-1.pooler.supabase.com",
                "DB_PROJECT_REF": "fsrbddgyysssqzyullrc",
                "PGHOST": "aws-1-ap-northeast-1.pooler.supabase.com",
                "PGUSER": "postgres.fsrbddgyysssqzyullrc",
            }
        )
        self.assertEqual(wrong_dev_project.returncode, 2)

    def test_writer_url_is_percent_encoded_to_runner_file_without_logging_password(self) -> None:
        env_file = self.root / "runner-env"
        password = "eight-characters:with@symbols%"
        result = subprocess.run(
            [sys.executable, str(URL_WRITER), "--output", str(env_file)],
            env={
                **self.env,
                "PGHOST": "aws-1-us-east-2.pooler.supabase.com",
                "PGPORT": "5432",
                "PGDATABASE": "postgres",
                "PGUSER": "postgres.projectref1234567890",
                "PGPASSWORD": password,
                "PGSSLMODE": "require",
            },
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(password, result.stdout + result.stderr)
        self.assertNotIn("%3Awith%40symbols%25", result.stdout + result.stderr)
        self.assertIn("%3Awith%40symbols%25", env_file.read_text(encoding="utf-8"))

        invalid = subprocess.run(
            [sys.executable, str(URL_WRITER), "--output", str(env_file)],
            env={
                **self.env,
                "PGHOST": "aws-1-us-east-2.pooler.supabase.com",
                "PGPORT": "5432",
                "PGDATABASE": "postgres",
                "PGUSER": "postgres.projectref1234567890",
                "PGPASSWORD": password + "\nunsafe",
                "PGSSLMODE": "require",
            },
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(invalid.returncode, 2)
        self.assertNotIn(password, invalid.stdout + invalid.stderr)

    def test_pending_runs_supabase_cli_with_vault_updates_disabled(self) -> None:
        marker = self.root / "cli-args"
        cli = self.bin / "supabase"
        cli.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "open(os.environ['FAKE_CLI_CAPTURE'], 'w').write('\\n'.join(sys.argv[1:]))\n",
            encoding="utf-8",
        )
        cli.chmod(0o700)
        result = self._run_apply("", cli, cli_capture=marker)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pending migrations submitted", result.stdout)
        self.assertNotIn("do-not-log-secret", result.stdout + result.stderr)
        cli_args = marker.read_text(encoding="utf-8").splitlines()
        self.assertIn("--skip-vault", cli_args)
        self.assertIn("--yes", cli_args)
        self.assertIn("postgresql://" + "writer" + ":" + "do-not-log-secret" + "@localhost/postgres", cli_args)

        failing_cli = self.bin / "failing-supabase"
        failing_cli.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "sys.stderr.write('failed do-not-log-secret\\n')\n"
            "raise SystemExit(1)\n",
            encoding="utf-8",
        )
        failing_cli.chmod(0o700)
        failed = self._run_apply("", failing_cli)
        self.assertEqual(failed.returncode, 2)
        self.assertIn("Supabase migration command failed", failed.stderr)
        self.assertNotIn("do-not-log-secret", failed.stdout + failed.stderr)

    def test_in_sync_skips_supabase_cli_and_remote_only_fails_closed(self) -> None:
        marker = self.root / "cli-invoked"
        cli = self.bin / "must-not-run"
        cli.write_text(
            "#!/usr/bin/env python3\n"
            "from pathlib import Path\n"
            f"Path({str(marker)!r}).write_text('called')\n"
            "raise SystemExit(99)\n",
            encoding="utf-8",
        )
        cli.chmod(0o700)
        in_sync = self._run_apply("20260101000000\n", cli)
        self.assertEqual(in_sync.returncode, 0, in_sync.stderr)
        self.assertIn("IN_SYNC; safe no-op", in_sync.stdout)
        self.assertFalse(marker.exists())

        remote_only = self._run_apply("20260101000000\n20250101000000\n", cli)
        self.assertEqual(remote_only.returncode, 2)
        self.assertIn("REMOTE_ONLY", remote_only.stderr)
        self.assertFalse(marker.exists())

    def test_connection_errors_are_sanitized_and_do_not_call_cli(self) -> None:
        marker = self.root / "cli-invoked"
        cli = self.bin / "must-not-run"
        cli.write_text(
            "#!/usr/bin/env python3\n"
            "from pathlib import Path\n"
            f"Path({str(marker)!r}).write_text('called')\n",
            encoding="utf-8",
        )
        cli.chmod(0o700)
        env = {
            **self.env,
            "SUPABASE_DB_URL": "postgresql://" + "writer" + ":" + "do-not-log-secret" + "@localhost/postgres",
            "FAKE_PSQL_ERROR": "1",
        }
        fake_psql = self.bin / "psql"
        fake_psql.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "sys.stderr.write('failure do-not-log-secret\\n'); raise SystemExit(2)\n",
            encoding="utf-8",
        )
        fake_psql.chmod(0o700)
        result = subprocess.run(
            [
                sys.executable,
                str(APPLY),
                "--repo",
                str(self.repo),
                "--migrations-dir",
                str(self.migrations),
                "--base-ref",
                self.base_ref,
                "--psql",
                str(fake_psql),
                "--supabase",
                str(cli),
            ],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("do-not-log-secret", result.stdout + result.stderr)
        self.assertFalse(marker.exists())

    def test_writer_environment_protection_requires_main_and_prod_review(self) -> None:
        base = {
            "name": "production-db-apply",
            "can_admins_bypass": False,
            "deployment_branch_policy": {"custom_branch_policies": True, "protected_branches": False},
            "protection_rules": [
                {"id": 1, "type": "branch_policy"},
                {
                    "id": 2,
                    "type": "required_reviewers",
                    "reviewers": [{"type": "User", "reviewer": {"type": "User", "id": 9, "login": "reviewer"}}],
                    "prevent_self_review": False,
                },
            ],
        }
        from importlib.util import module_from_spec, spec_from_file_location

        spec = spec_from_file_location("check_writer_environment", ENV_CHECK)
        assert spec and spec.loader
        module = module_from_spec(spec)
        spec.loader.exec_module(module)
        main_policy = {"total_count": 1, "branch_policies": [{"id": 1, "name": "main", "type": "branch"}]}
        message = module.validate(base, main_policy, "production")
        self.assertIn("self-approval", message)
        team_reviewer = {
            **base,
            "protection_rules": [
                base["protection_rules"][0],
                {
                    "id": 2,
                    "type": "required_reviewers",
                    "reviewers": [{"type": "Team", "reviewer": {"id": 7, "slug": "db-ops", "name": "DB Ops"}}],
                    "prevent_self_review": True,
                },
            ],
        }
        self.assertIn("self-review is prevented", module.validate(team_reviewer, main_policy, "production"))
        invalid = {**base, "can_admins_bypass": True}
        with self.assertRaises(module.EnvironmentError):
            module.validate(invalid, main_policy, "production")
        with self.assertRaises(module.EnvironmentError):
            module.validate(base, {"total_count": 2, "branch_policies": [
                {"id": 1, "name": "main", "type": "branch"},
                {"id": 2, "name": "release", "type": "branch"},
            ]}, "production")
        for invalid_policy in (
            {"total_count": 1, "branch_policies": [{"id": 1, "name": "main", "type": "tag"}]},
            {"total_count": 1, "branch_policies": [{"id": 1, "name": "release", "type": "branch"}]},
            {"branch_policies": [{"id": 1, "name": "main", "type": "branch"}]},
            {"total_count": 2, "branch_policies": [{"id": 1, "name": "main", "type": "branch"}]},
        ):
            with self.subTest(policy=invalid_policy), self.assertRaises(module.EnvironmentError):
                module.validate(base, invalid_policy, "production")
        incomplete = {**base, "deployment_branch_policy": {"custom_branch_policies": True}}
        with self.assertRaises(module.EnvironmentError):
            module.validate(incomplete, main_policy, "production")
        unknown_rule = {**base, "protection_rules": [*base["protection_rules"], {"id": 3, "type": "future_rule"}]}
        with self.assertRaises(module.EnvironmentError):
            module.validate(unknown_rule, main_policy, "production")

    def test_workflow_result_gate_covers_success_failure_and_unexpected_skip(self) -> None:
        def outcome(state: str, preflight: str, environment: str, apply: str, postflight: str) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                [sys.executable, str(WORKFLOW_RESULT), "--state", state, "--preflight", preflight,
                 "--environment", environment, "--apply", apply, "--postflight", postflight],
                capture_output=True, text=True, check=False,
            )

        synced = outcome("IN_SYNC", "success", "skipped", "skipped", "success")
        self.assertEqual(synced.returncode, 0, synced.stderr)
        pending = outcome("PENDING", "success", "success", "success", "success")
        self.assertEqual(pending.returncode, 0, pending.stderr)
        for failed in (
            outcome("PENDING", "success", "success", "failure", "success"),
            outcome("PENDING", "success", "success", "skipped", "skipped"),
            outcome("PENDING", "success", "success", "success", "failure"),
            outcome("REMOTE_ONLY", "success", "skipped", "skipped", "skipped"),
            outcome("PENDING", "failure", "skipped", "skipped", "skipped"),
        ):
            self.assertNotEqual(failed.returncode, 0)

    def test_dev_writer_gate_is_closed_until_explicit_cutover_enablement(self) -> None:
        def check(value: str | None) -> subprocess.CompletedProcess[str]:
            env = {**self.env}
            if value is not None:
                env["DEV_DB_WRITER_ENABLED"] = value
            else:
                env.pop("DEV_DB_WRITER_ENABLED", None)
            return subprocess.run([sys.executable, str(DEV_WRITER_GATE)], env=env, capture_output=True, text=True)

        self.assertEqual(check("true").returncode, 0)
        for value in (None, "", "false", "TRUE", "yes"):
            with self.subTest(value=value):
                result = check(value)
                self.assertEqual(result.returncode, 2)
                self.assertIn("complete the documented cutover", result.stderr)

    def test_database_identity_verifier_uses_read_only_query_and_fails_closed(self) -> None:
        fake_psql = self.bin / "psql"
        fake_psql.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "open(os.environ['IDENTITY_QUERY_CAPTURE'], 'w').write(sys.argv[-1])\n"
            "if os.environ.get('IDENTITY_PSQL_FAIL') == '1':\n"
            " sys.stderr.write('connection error ' + os.environ.get('PGPASSWORD', '') + '\\n'); raise SystemExit(2)\n"
            "print(os.environ.get('IDENTITY_PSQL_OUTPUT', ''))\n",
            encoding="utf-8",
        )
        fake_psql.chmod(0o700)
        output_path = self.root / "identity-query.sql"
        base = {
            **self.env,
            "DB_TARGET": "dev",
            "PGPASSWORD": "identity-probe-secret",
            "IDENTITY_QUERY_CAPTURE": str(output_path),
            "IDENTITY_PSQL_OUTPUT": "shared-supabase-db:target=dev;project_ref=irgahixsuvtopiwmtkku",
        }
        success = subprocess.run([sys.executable, str(IDENTITY_CHECK)], env=base, capture_output=True, text=True)
        self.assertEqual(success.returncode, 0, success.stderr)
        self.assertIn("BEGIN TRANSACTION READ ONLY", output_path.read_text(encoding="utf-8"))
        self.assertIn("pg_catalog.shobj_description", output_path.read_text(encoding="utf-8"))
        self.assertNotIn("identity-probe-secret", success.stdout + success.stderr)

        wrong_project = subprocess.run(
            [sys.executable, str(IDENTITY_CHECK)],
            env={**base, "IDENTITY_PSQL_OUTPUT": "shared-supabase-db:target=production;project_ref=fsrbddgyysssqzyullrc"},
            capture_output=True,
            text=True,
        )
        self.assertEqual(wrong_project.returncode, 1)
        self.assertIn("missing or mismatched", wrong_project.stderr)
        self.assertNotIn("identity-probe-secret", wrong_project.stdout + wrong_project.stderr)

        unavailable = subprocess.run(
            [sys.executable, str(IDENTITY_CHECK)],
            env={**base, "IDENTITY_PSQL_FAIL": "1"},
            capture_output=True,
            text=True,
        )
        self.assertEqual(unavailable.returncode, 2)
        self.assertNotIn("identity-probe-secret", unavailable.stdout + unavailable.stderr)

    def test_dev_writer_environment_requires_main_policy_and_independent_reviewer(self) -> None:
        from importlib.util import module_from_spec, spec_from_file_location

        spec = spec_from_file_location("check_writer_environment_dev", ENV_CHECK)
        assert spec and spec.loader
        module = module_from_spec(spec)
        spec.loader.exec_module(module)
        environment = {
            "name": "development-db-apply",
            "can_admins_bypass": False,
            "deployment_branch_policy": {"custom_branch_policies": True, "protected_branches": False},
            "protection_rules": [
                {"id": 1, "type": "branch_policy"},
                {
                    "id": 2,
                    "type": "required_reviewers",
                    "reviewers": [{"type": "User", "reviewer": {"type": "User", "id": 8, "login": "reviewer"}}],
                    "prevent_self_review": True,
                },
            ],
        }
        policy = {"total_count": 1, "branch_policies": [{"id": 1, "name": "main", "type": "branch"}]}
        self.assertIn("self-approval prevented", module.validate(environment, policy, "dev"))
        no_reviewer = {**environment, "protection_rules": [environment["protection_rules"][0]]}
        with self.assertRaises(module.EnvironmentError):
            module.validate(no_reviewer, policy, "dev")
        self_approval_allowed = {
            **environment,
            "protection_rules": [environment["protection_rules"][0], {
                **environment["protection_rules"][1], "prevent_self_review": False,
            }],
        }
        with self.assertRaises(module.EnvironmentError):
            module.validate(self_approval_allowed, policy, "dev")

    def test_writer_workflows_are_manual_target_specific_and_least_permission(self) -> None:
        dev = (ROOT / ".github/workflows/apply-dev-db-migrations.yml").read_text(encoding="utf-8")
        prod = (ROOT / ".github/workflows/apply-production-db-migrations.yml").read_text(encoding="utf-8")
        reusable = (ROOT / ".github/workflows/_apply-db-migrations.yml").read_text(encoding="utf-8")
        for workflow in (dev, prod):
            self.assertIn("workflow_dispatch:", workflow)
            self.assertIn("contents: read", workflow)
            self.assertNotIn("push:", workflow)
            self.assertNotIn("pull_request:", workflow)
            self.assertNotIn("contents: write", workflow)
            self.assertIn("uses: ./.github/workflows/_apply-db-migrations.yml", workflow)
        self.assertIn("target: dev", dev)
        self.assertIn("target: production", prod)
        self.assertIn("actions: read", reusable)
        self.assertIn("scripts/assert-latest-main.py", reusable)
        self.assertIn("scripts/check-writer-environment.py", reusable)
        self.assertIn("scripts/validate-writer-db-env.py", reusable)
        self.assertIn("scripts/apply-pending-migrations.py", reusable)
        self.assertIn("scripts/evaluate-db-migration-workflow.py", reusable)
        self.assertIn("scripts/verify-db-project-identity.py", reusable)
        self.assertIn("scripts/require-dev-writer-enabled.py", reusable)
        self.assertIn("needs.preflight.outputs.state == 'IN_SYNC'", reusable)
        self.assertIn("needs.preflight.outputs.state == 'PENDING'", reusable)
        self.assertIn("needs.apply.result == 'failure'", reusable)
        self.assertIn("final-result:", reusable)
        self.assertIn("if: always()", reusable)
        self.assertIn("MIGRATION_SUPABASE_DB_PASSWORD", reusable)
        self.assertIn("DEV_MIGRATION_SUPABASE_DB_PASSWORD", reusable)
        self.assertIn("Verify current pinned app contracts before apply", reusable)
        self.assertIn("Verify current pinned app contracts after apply", reusable)
        self.assertIn("(inputs.target == 'dev' && vars.DEV_SUPABASE_POOLER_HOST)", reusable)
        self.assertIn("(inputs.target == 'production' && vars.PROD_SUPABASE_POOLER_HOST)", reusable)
        self.assertIn("|| ''", reusable)
        self.assertNotIn("|| vars.PROD_SUPABASE_POOLER_HOST", reusable)
        self.assertNotIn("|| secrets.MIGRATION_READER_PASSWORD", reusable)
        self.assertNotIn("supabase db push", reusable)

        probe = (ROOT / ".github/workflows/verify-dev-db-writer-connection.yml").read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", probe)
        self.assertIn("contents: read", probe)
        self.assertIn("actions: read", probe)
        self.assertIn("development-db-check", probe)
        self.assertIn("development-db-apply", probe)
        self.assertIn("DEV_MIGRATION_SUPABASE_DB_PASSWORD", probe)
        self.assertIn("scripts/verify-db-project-identity.py", probe)
        self.assertIn("scripts/check-writer-environment.py", probe)
        self.assertNotIn("supabase db push", probe)
        self.assertNotIn("pull_request:", probe)
        self.assertNotIn("push:", probe)
        self.assertNotIn("contents: write", probe)
        self.assertLess(probe.index("verify-reader:"), probe.index("verify-writer-environment:"))
        self.assertLess(probe.index("verify-writer-environment:"), probe.index("verify-writer-credentials:"))
        self.assertIn("DEV_DB_WRITER_ENABLED: ${{ vars.DEV_DB_WRITER_ENABLED }}", reusable)
        self.assertLess(
            reusable.index("Require explicit Dev Writer handoff enablement"),
            reusable.index("Verify Dev database-side project identity as Writer"),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
