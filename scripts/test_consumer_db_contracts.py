"""Tests for immutable public contract references and fail-closed acquisition."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import consumer_db_contracts as consumer
from db_contract import ContractError, validate_contract


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = json.loads((ROOT / "scripts/fixtures/db-contract-v1.example.json").read_text())


class ConsumerContractFetchTests(unittest.TestCase):
    def test_references_are_full_fixed_shas_and_consumer_owned_paths(self) -> None:
        self.assertEqual(
            [(item.repository, item.path, item.commit) for item in consumer.CONTRACTS],
            [
                ("nakakonakako/price-memo", "db-contracts/price-memo.json", "7620cc8e43ef1defeaa0700d6ad0d509097ae52d"),
                ("nakakonakako/receipt-manager", "db-contracts/receipt-manager.json", "2c6803cdd7dbc31d441c822df23027f2ddc3f6ce"),
            ],
        )
        self.assertTrue(all(consumer.SHA.fullmatch(item.commit) for item in consumer.CONTRACTS))

    def test_fetch_checks_commit_identity_then_parses_and_validates_contract(self) -> None:
        spec = consumer.CONTRACTS[0]
        payloads = [json.dumps({"sha": spec.commit}).encode(), json.dumps({**FIXTURE, "app_id": spec.app_id}).encode()]
        with patch.object(consumer, "_request", side_effect=payloads) as request:
            result = consumer.fetch_contract(spec)
        self.assertEqual(result["app_id"], spec.app_id)
        self.assertIn(spec.commit, request.call_args_list[0].args[0])
        self.assertIn(spec.commit, request.call_args_list[1].args[0])
        self.assertIn(spec.path, request.call_args_list[1].args[0])

    def test_deployment_contract_uses_callers_exact_revision(self) -> None:
        deployment_sha = "a" * 40
        spec = consumer.contract_for_revision("price-memo", deployment_sha)
        self.assertEqual(spec.repository, "nakakonakako/price-memo")
        self.assertEqual(spec.path, "db-contracts/price-memo.json")
        self.assertEqual(spec.commit, deployment_sha)
        payloads = [json.dumps({"sha": deployment_sha}).encode(), json.dumps({**FIXTURE, "app_id": "price-memo"}).encode()]
        with patch.object(consumer, "_request", side_effect=payloads) as request:
            self.assertEqual(consumer.fetch_contract(spec)["app_id"], "price-memo")
        self.assertIn(deployment_sha, request.call_args_list[0].args[0])
        self.assertIn(deployment_sha, request.call_args_list[1].args[0])
        with self.assertRaises(consumer.ContractFetchError):
            consumer.contract_for_revision("price-memo", "short-sha")

    def test_composite_action_uses_reader_only_configuration_and_is_documented(self) -> None:
        action = (ROOT / ".github/actions/consumer-production-db-check/action.yml").read_text()
        docs = (ROOT / "docs/db-compatibility-contracts.md").read_text()
        self.assertIn("using: composite", action)
        self.assertIn("PGPASSWORD: ${{ inputs.reader-password }}", action)
        self.assertIn("DB_CONNECTION_ROLE: reader", action)
        self.assertNotIn("contents: write", action)
        self.assertIn("runs-on: ubuntu-latest", docs)
        self.assertIn("actions/setup-python@v5", docs)
        self.assertIn("git postgresql-client", docs)
        self.assertIn("app-id: receipt-manager", docs)
        self.assertIn("app-id: price-memo", docs)
        self.assertIn("production-db-check", docs)
        self.assertIn("0123456789abcdef0123456789abcdef01234567", docs)

    def test_composite_action_entrypoint_resolves_and_passes_input_environment(self) -> None:
        action_path = ROOT / ".github/actions/consumer-production-db-check"
        action_text = (action_path / "action.yml").read_text()
        run_match = re.search(r"^\s+run: (.+)$", action_text, re.MULTILINE)
        self.assertIsNotNone(run_match)
        input_values = {
            "app-id": "price-memo",
            "app-commit-sha": "a" * 40,
            "reader-pooler-host": "aws-1-us-east-1.pooler.supabase.com",
            "reader-project-ref": "fsrbddgyysssqzyullrc",
            "reader-username": "migration_preflight_login.fsrbddgyysssqzyullrc",
            "reader-password": "disposable-action-test-password",
        }
        mapped_env: dict[str, str] = {}
        in_env = False
        for line in action_text.splitlines():
            if line.strip() == "env:":
                in_env = True
                continue
            if in_env and line.startswith("      run:"):
                break
            if in_env:
                mapping = re.match(r"\s{8}([A-Z_]+):\s*(.+)$", line)
                if mapping:
                    name, value = mapping.groups()
                    value = value.strip().strip('"')
                    input_match = re.fullmatch(r"\$\{\{\s*inputs\.([a-z-]+)\s*\}\}", value)
                    mapped_env[name] = input_values[input_match.group(1)] if input_match else value

        sitecustomize = r'''import json
import os
import subprocess
from pathlib import Path

def _fake_run(command, *, cwd=None, env=None, **kwargs):
    args = [str(value) for value in command]
    joined = " ".join(args)
    if args[:2] == ["git", "ls-remote"]:
        repo = args[2]
        sha = "a" * 40 if "price-memo.git" in repo else "b" * 40
        return subprocess.CompletedProcess(args, 0, sha + "\trefs/heads/main\n", "")
    if "--validate-only" in args and "verify-consumer-db-contracts.py" in joined:
        contract_dir = Path(args[args.index("--contracts-dir") + 1])
        contract_dir.mkdir(parents=True, exist_ok=True)
        contract = json.loads(Path(os.environ["TEST_CONTRACT_FIXTURE_PATH"]).read_text())
        contract["app_id"] = os.environ["INPUT_APP_ID"]
        (contract_dir / (os.environ["INPUT_APP_ID"] + ".json")).write_text(json.dumps(contract))
        return subprocess.CompletedProcess(args, 0, "price-memo: CONTRACT FORMAT PASS", "")
    if "verify-consumer-db-contracts.py" in joined:
        return subprocess.CompletedProcess(args, 0, "price-memo: STATIC PASS (3 catalog assertions)\nDB contract aggregate: STATIC PASS (1 contract)", "")
    if "check-migration-history.py" in joined:
        Path(args[args.index("--output") + 1]).write_text("state=IN_SYNC\n")
        return subprocess.CompletedProcess(args, 0, "migration preflight: IN_SYNC", "")
    if "verify-db-project-identity.py" in joined:
        return subprocess.CompletedProcess(args, 0, "database identity verification: production server-side marker matches", "")
    if any(script in joined for script in ("validate-writer-db-env.py", "check-migrations.py")):
        return subprocess.CompletedProcess(args, 0, "PASS", "")
    if args[:2] == ["git", "init"] or args[:2] == ["git", "-C"]:
        return subprocess.CompletedProcess(args, 0, "", "")
    raise AssertionError("unexpected subprocess in composite test: " + joined)

subprocess.run = _fake_run
'''
        with tempfile.TemporaryDirectory(prefix="composite-action-test-") as temp:
            sitecustomize_path = Path(temp, "sitecustomize.py")
            sitecustomize_path.write_text(sitecustomize, encoding="utf-8")
            fixture_path = Path(temp, "contract.json")
            fixture_path.write_text(json.dumps(FIXTURE), encoding="utf-8")
            env = os.environ.copy()
            env.update({
                "GITHUB_ACTION_PATH": str(action_path),
                "GITHUB_REPOSITORY": "nakakonakako/price-memo",
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_SHA": "a" * 40,
                "TEST_CONTRACT_FIXTURE_PATH": str(fixture_path),
                "PYTHONPATH": temp,
                **mapped_env,
            })
            result = subprocess.run(["bash", "-c", run_match.group(1)], env=env, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("price-memo: STATIC PASS", result.stdout)
        self.assertIn("shared migration history: IN_SYNC", result.stdout)
        self.assertIn("deploy DB gate: PASS", result.stdout)
        self.assertNotIn(input_values["reader-password"], result.stdout + result.stderr)

    def test_mismatched_commit_and_invalid_contract_fail_closed(self) -> None:
        spec = consumer.CONTRACTS[0]
        with patch.object(consumer, "_request") as request:
            with self.assertRaisesRegex(consumer.ContractFetchError, "40-character"):
                consumer.fetch_contract(replace(spec, commit="not-a-full-sha"))
        request.assert_not_called()
        with patch.object(consumer.urllib.request, "urlopen", side_effect=OSError("network unavailable")):
            with self.assertRaisesRegex(consumer.ContractFetchError, "could not be fetched"):
                consumer._request("https://api.github.com/test")
        with patch.object(consumer, "_request", return_value=json.dumps({"sha": "0" * 40}).encode()):
            with self.assertRaisesRegex(consumer.ContractFetchError, "did not match"):
                consumer.fetch_contract(spec)
        with patch.object(consumer, "_request", side_effect=[json.dumps({"sha": spec.commit}).encode(), b"not json"]):
            with self.assertRaisesRegex(consumer.ContractFetchError, "not valid"):
                consumer.fetch_contract(spec)
        with patch.object(consumer, "_request", side_effect=[json.dumps({"sha": spec.commit}).encode(), json.dumps(FIXTURE).encode()]):
            with self.assertRaisesRegex(consumer.ContractFetchError, "app_id"):
                consumer.fetch_contract(spec)

    def test_unsupported_contract_semantics_fail_closed(self) -> None:
        invalid = {**FIXTURE, "unsupported": True}
        with self.assertRaises(ContractError):
            validate_contract(invalid)

    def test_production_workflow_is_manual_main_only_and_reads_existing_environment(self) -> None:
        workflow = (ROOT / ".github/workflows/consumer-db-contract-check.yml").read_text()
        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("pull_request:", workflow)
        self.assertNotIn("push:", workflow)
        self.assertIn("permissions:\n  contents: read", workflow)
        self.assertIn("name: production-db-check", workflow)
        self.assertIn("scripts/assert-latest-main.py", workflow)
        self.assertIn("scripts/verify-consumer-db-contracts.py --validate-only", workflow)
        self.assertIn("scripts/verify-consumer-db-contracts.py --contracts-dir", workflow)
        self.assertLess(
            workflow.index("Fetch and validate both pinned contracts before DB access"),
            workflow.index("PGPASSWORD: ${{ secrets.MIGRATION_READER_PASSWORD }}"),
        )
        self.assertNotIn("contents: write", workflow)


if __name__ == "__main__":
    unittest.main()
