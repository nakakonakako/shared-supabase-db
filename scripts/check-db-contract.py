#!/usr/bin/env python3
"""Validate a consumer contract, then optionally compare it to PG catalogs."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from db_contract import ContractError, VerificationError, load_contract, verify_catalog


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("contract", type=Path, help="consumer-owned JSON contract")
    parser.add_argument("--validate-only", action="store_true", help="validate format without connecting")
    parser.add_argument("--psql", default="psql", help="psql executable (default: psql on PATH)")
    args = parser.parse_args()

    try:
        contract = load_contract(args.contract)
    except ContractError as exc:
        print(f"DB contract invalid: {exc}", file=sys.stderr)
        return 2

    if args.validate_only:
        print(f"DB contract format valid: {contract['app_id']} contract {contract['contract_version']}")
        return 0

    try:
        results = verify_catalog(contract, psql=args.psql)
    except VerificationError:
        print("DB contract catalog verification failed or was inconclusive", file=sys.stderr)
        return 2
    failed = [result.label for result in results if not result.passed]
    if failed:
        for label in failed:
            print(f"DB contract mismatch: {label}", file=sys.stderr)
        print(f"DB contract: FAIL ({len(failed)} of {len(results)} static assertions)", file=sys.stderr)
        return 1
    print(f"DB contract: STATIC PASS ({len(results)} catalog assertions)")
    print("RLS row behavior, Auth-user isolation, RPC outcomes, and Realtime delivery require isolated runtime tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
