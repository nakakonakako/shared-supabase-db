#!/usr/bin/env python3
"""Fail the workflow unless migration apply and Reader postflight outcomes agree."""

from __future__ import annotations

import argparse
import sys


def successful(state: str, preflight: str, environment: str, apply: str, postflight: str) -> bool:
    if preflight != "success" or postflight != "success":
        return False
    if state == "IN_SYNC":
        return environment == "skipped" and apply == "skipped"
    if state == "PENDING":
        return environment == "success" and apply == "success"
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True)
    parser.add_argument("--preflight", required=True)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--apply", required=True)
    parser.add_argument("--postflight", required=True)
    args = parser.parse_args()
    if not successful(args.state, args.preflight, args.environment, args.apply, args.postflight):
        print("migration workflow result: required migration or verification outcome was not successful", file=sys.stderr)
        return 1
    print(f"migration workflow result: {args.state} verification successful")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
