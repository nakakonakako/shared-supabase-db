"""Tests for immutable public contract references and fail-closed acquisition."""

from __future__ import annotations

import json
import sys
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
        self.assertIn("app-id: receipt-manager", docs)
        self.assertIn("app-id: price-memo", docs)
        self.assertIn("production-db-check", docs)
        self.assertIn("<SHARED_ACTION_SHA>", docs)

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
