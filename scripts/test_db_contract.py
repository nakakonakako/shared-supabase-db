"""Unit and mocked-psql tests for consumer DB contract v1."""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from db_contract import ContractError, VerificationError, build_checks, load_contract, validate_contract, verify_catalog

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "scripts/fixtures/db-contract-v1.example.json"
CLI = ROOT / "scripts/check-db-contract.py"


class DbContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.valid = load_contract(FIXTURE)

    def test_valid_fixture_covers_catalog_contract_sections(self) -> None:
        checks = build_checks(self.valid)
        labels = [label for label, _ in checks]
        self.assertTrue(any("column public.fixture_items.id" in label for label in labels))
        self.assertTrue(any("constraint public.fixture_items" in label for label in labels))
        self.assertTrue(any("policy public.fixture_items" in label for label in labels))
        self.assertTrue(any("function public.fixture_lookup(uuid)" in label for label in labels))
        self.assertTrue(any("argument names" in label for label in labels))
        self.assertTrue(any("argument modes" in label for label in labels))
        self.assertTrue(any("argument types" in label for label in labels))
        self.assertTrue(any("set-returning mode" in label for label in labels))
        self.assertTrue(any("ordinary function" in label for label in labels))
        self.assertTrue(any("relation public.relation_probe kind=table" in label for label in labels))
        self.assertTrue(any("convalidated" in query for _, query in checks))
        self.assertTrue(any("Auth FK" in label for label in labels))
        self.assertTrue(any("Realtime relation" in label for label in labels))
        self.assertTrue(any("Realtime trigger" in label for label in labels))

    def test_invalid_shape_and_unsupported_fields_fail_closed(self) -> None:
        invalids = []
        malformed = copy.deepcopy(self.valid)
        malformed["format_version"] = 99
        invalids.append(malformed)
        bad_contract_version = copy.deepcopy(self.valid)
        bad_contract_version["contract_version"] = "0"
        invalids.append(bad_contract_version)
        unsupported = copy.deepcopy(self.valid)
        unsupported["capabilities"]["tables"][0]["columns"][0]["default"] = "gen_random_uuid()"
        invalids.append(unsupported)
        unsupported_check = copy.deepcopy(self.valid)
        unsupported_check["capabilities"]["functions"][0]["volatility"] = "immutable"
        invalids.append(unsupported_check)
        bad_policy = copy.deepcopy(self.valid)
        bad_policy["capabilities"]["tables"][0]["rls"]["policies"][0]["using_expression"] = "auth.uid() = user_id"
        invalids.append(bad_policy)
        malformed_array = copy.deepcopy(self.valid)
        malformed_array["capabilities"]["tables"][0]["constraints"] = None
        invalids.append(malformed_array)
        malformed_enum = copy.deepcopy(self.valid)
        malformed_enum["capabilities"]["functions"][0]["security"] = ["definer"]
        invalids.append(malformed_enum)
        malformed_arg_mode = copy.deepcopy(self.valid)
        malformed_arg_mode["capabilities"]["functions"][0]["arguments"][0]["mode"] = "INPUT"
        invalids.append(malformed_arg_mode)
        missing_record_shape = copy.deepcopy(self.valid)
        missing_record_shape["capabilities"]["functions"].append(
            {"signature": "public.record_result()", "returns": "record", "security": "invoker", "execute": {"allow": [], "deny": []}}
        )
        invalids.append(missing_record_shape)
        invalid_fk_validation = copy.deepcopy(self.valid)
        invalid_fk_validation["capabilities"]["tables"][0]["constraints"][2]["validated"] = "false"
        invalids.append(invalid_fk_validation)
        for contract in invalids:
            with self.subTest(contract=contract):
                with self.assertRaises(ContractError):
                    validate_contract(contract)

    def test_contract_assertions_follow_only_declared_requirements(self) -> None:
        checks_before = build_checks(self.valid)
        extended = copy.deepcopy(self.valid)
        extended["capabilities"]["tables"][0]["columns"].append(
            {"name": "future_optional", "type": "text", "nullable": True}
        )
        extended["capabilities"]["tables"].append(
            {"schema": "public", "name": "unrelated_new_table", "columns": [{"name": "id", "type": "uuid", "nullable": False}]}
        )
        checks_after = build_checks(validate_contract(extended))
        self.assertEqual(len(checks_after), len(checks_before) + 4)
        self.assertTrue(all("unrelated_new_table" not in label for label, _ in checks_before))

    def test_invalid_contract_cli_does_not_connect(self) -> None:
        with tempfile.TemporaryDirectory(prefix="db-contract-invalid-") as temp:
            path = Path(temp) / "bad.json"
            path.write_text('{"format_version":1,"unknown":true}', encoding="utf-8")
            result = subprocess.run([sys.executable, str(CLI), str(path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("DB contract invalid", result.stderr)

    def test_psql_mismatch_and_unexpected_results_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="db-contract-psql-") as temp:
            fake = Path(temp) / "psql"
            fake.write_text(
                "#!/usr/bin/env python3\n"
                "import os,sys\n"
                "args=sys.argv[1:]\n"
                "sql=args[args.index('-c')+1]\n"
                "capture=os.environ.get('FAKE_SQL_CAPTURE')\n"
                "if capture:\n open(capture,'a',encoding='utf-8').write(sql+'\\n')\n"
                "if 'BEGIN TRANSACTION READ ONLY' not in sql: sys.exit(9)\n"
                "if os.environ.get('FAKE_PSQL_ERROR') == '1': sys.exit(2)\n"
                "matches=[]\n"
                "offset=0\n"
                "for line in sql.splitlines(True):\n"
                " stripped=line.lstrip()\n"
                " if stripped.startswith('(') and ', ' in stripped and stripped[1:].split(',',1)[0].isdigit():\n"
                "  label=stripped.split(\", '\",1)[1].split(\"', (\",1)[0]\n"
                "  matches.append((offset+line.index(stripped),label))\n"
                " offset+=len(line)\n"
                "if not matches: sys.exit(8)\n"
                "for i,match in enumerate(matches):\n"
                " end=matches[i+1][0] if i+1<len(matches) else sql.rfind(') AS contract_checks')\n"
                " row=sql[match[0]:end]\n"
                " needle=os.environ.get('FAKE_FAIL_MATCH')\n"
                " print('f' if needle and needle in row else 't')\n"
                "if os.environ.get('FAKE_PSQL_OUTPUT') == 'weird': print('maybe')\n",
                encoding="utf-8",
            )
            fake.chmod(0o700)
            env = {**os.environ, "FAKE_SQL_CAPTURE": str(Path(temp) / "queries.sql")}
            good = verify_catalog(self.valid, psql=str(fake), env=env)
            self.assertTrue(good and all(result.passed for result in good))
            captured = Path(env["FAKE_SQL_CAPTURE"]).read_text()
            self.assertEqual(captured.count("BEGIN TRANSACTION READ ONLY"), 1)
            self.assertNotIn("INSERT INTO", captured.upper())

            missing_column = verify_catalog(self.valid, psql=str(fake), env={**env, "FAKE_FAIL_MATCH": "attname='label'"})
            self.assertTrue(any(not result.passed and "label" in result.label for result in missing_column))
            wrong_type = verify_catalog(self.valid, psql=str(fake), env={**env, "FAKE_FAIL_MATCH": "format_type"})
            self.assertTrue(any(not result.passed and "type/nullability" in result.label for result in wrong_type))
            wrong_nullability = verify_catalog(self.valid, psql=str(fake), env={**env, "FAKE_FAIL_MATCH": "attnotnull"})
            self.assertTrue(any(not result.passed and "type/nullability" in result.label for result in wrong_nullability))
            bad_rpc = verify_catalog(self.valid, psql=str(fake), env={**env, "FAKE_FAIL_MATCH": "prosecdef"})
            self.assertTrue(any(not result.passed and "security mode" in result.label for result in bad_rpc))
            for needle, label in (
                ("proargnames", "argument names"),
                ("proargmodes", "argument modes"),
                ("proretset", "set-returning mode"),
                ("prokind='f'", "ordinary function"),
                ("convalidated", "constraint public.fixture_items"),
                ("c.relkind", "relation public.relation_probe"),
            ):
                with self.subTest(catalog_property=needle):
                    drift = verify_catalog(self.valid, psql=str(fake), env={**env, "FAKE_FAIL_MATCH": needle})
                    self.assertTrue(any(not result.passed and label in result.label for result in drift))
            bad_grant = verify_catalog(self.valid, psql=str(fake), env={**env, "FAKE_FAIL_MATCH": "has_table_privilege"})
            self.assertTrue(any(not result.passed and "allowed" in result.label for result in bad_grant))

            with self.assertRaises(VerificationError):
                verify_catalog(self.valid, psql=str(fake), env={**env, "FAKE_PSQL_ERROR": "1"})
            with self.assertRaises(VerificationError):
                verify_catalog(self.valid, psql=str(fake), env={**env, "FAKE_PSQL_OUTPUT": "weird"})

            cli_env = {**env, "PATH": f"{temp}{os.pathsep}{os.environ['PATH']}", "FAKE_PSQL_ERROR": "1"}
            cli = subprocess.run([sys.executable, str(CLI), str(FIXTURE)], env=cli_env, capture_output=True, text=True)
            self.assertEqual(cli.returncode, 2)
            self.assertIn("catalog verification failed or was inconclusive", cli.stderr)
            self.assertNotIn("disposable", cli.stdout + cli.stderr)


if __name__ == "__main__":
    unittest.main()
