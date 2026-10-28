#!/usr/bin/env python3
"""Fetch pinned consumer contracts and compare them with read-only catalogs."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from consumer_db_contracts import CONTRACTS, ContractFetchError, fetch_contract
from db_contract import ContractError, VerificationError, load_contract, verify_catalog


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--psql", default="psql", help="psql executable (default: psql on PATH)")
    parser.add_argument("--contracts-dir", type=Path, help="use previously fetched and validated contracts from this directory")
    parser.add_argument("--validate-only", action="store_true", help="fetch and validate pinned contracts without connecting")
    args = parser.parse_args()

    fetched = []
    retrieval_failed = False
    for spec in CONTRACTS:
        try:
            if args.validate_only or args.contracts_dir is None:
                contract = fetch_contract(spec)
            else:
                contract = load_contract(args.contracts_dir / f"{spec.app_id}.json")
                if contract["app_id"] != spec.app_id:
                    raise ContractFetchError("contract app_id does not match its repository")
            fetched.append((spec, contract, None))
        except (ContractFetchError, ContractError, OSError) as exc:
            fetched.append((spec, None, str(exc)))
            retrieval_failed = True

    if retrieval_failed:
        for spec, contract, error in fetched:
            if error:
                print(f"{spec.app_id}: EXECUTION ERROR ({error})", file=sys.stderr)
            elif contract:
                print(f"{spec.app_id}: EXECUTION ERROR (verification skipped because a pinned contract failed retrieval/format validation)", file=sys.stderr)
        print("DB contract aggregate: FAIL", file=sys.stderr)
        return 2

    if args.validate_only:
        if args.contracts_dir is None:
            parser.error("--validate-only requires --contracts-dir")
        args.contracts_dir.mkdir(parents=True, exist_ok=True)
        for spec, contract, _ in fetched:
            (args.contracts_dir / f"{spec.app_id}.json").write_text(
                json.dumps(contract, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
            )
            print(f"{spec.app_id}: CONTRACT FORMAT PASS (revision {spec.commit})")
        print("DB contract format aggregate: PASS (2 contracts)")
        return 0

    failed = False
    execution_error = False
    for spec, contract, _ in fetched:
        try:
            results = verify_catalog(contract, psql=args.psql)
        except VerificationError:
            print(f"{spec.app_id}: EXECUTION ERROR (catalog verification failed or was inconclusive)", file=sys.stderr)
            failed = True
            execution_error = True
            continue
        mismatches = [result.label for result in results if not result.passed]
        if mismatches:
            for label in mismatches:
                print(f"{spec.app_id}: CONTRACT MISMATCH: {label}", file=sys.stderr)
            print(f"{spec.app_id}: CONTRACT MISMATCH ({len(mismatches)} of {len(results)} assertions)", file=sys.stderr)
            failed = True
        else:
            print(f"{spec.app_id}: STATIC PASS ({len(results)} catalog assertions)")

    if failed:
        print("DB contract aggregate: FAIL", file=sys.stderr)
        return 2 if execution_error else 1
    print("DB contract aggregate: STATIC PASS (2 contracts)")
    print("RLS row behavior, Auth-user isolation, RPC outcomes, and Realtime delivery require isolated runtime tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
