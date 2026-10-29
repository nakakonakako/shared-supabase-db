#!/usr/bin/env python3
"""Run the read-only production DB gate for one app deployment revision."""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from consumer_db_contracts import CONTRACTS, SHA  # noqa: E402

APP_REPOSITORIES = {item.app_id: item.repository for item in CONTRACTS}
SHARED_REPOSITORY = "nakakonakako/shared-supabase-db"


class GateError(RuntimeError):
    pass


def run(command: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None, timeout: int = 90) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, cwd=cwd, env=env, check=False, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        raise GateError("required verification command could not execute") from None


def remote_main(repository: str) -> str:
    result = run(["git", "ls-remote", f"https://github.com/{repository}.git", "refs/heads/main"], timeout=30)
    sha = result.stdout.split(maxsplit=1)[0] if result.returncode == 0 and result.stdout.strip() else ""
    if not SHA.fullmatch(sha):
        raise GateError("could not resolve a full main revision")
    return sha


def require_success(command: list[str], label: str, *, cwd: Path | None = None, env: dict[str, str] | None = None) -> str:
    result = run(command, cwd=cwd, env=env)
    if result.returncode != 0:
        raise GateError(f"{label} failed (exit {result.returncode})")
    return result.stdout.strip()


def main() -> int:
    app_id = os.environ.get("INPUT_APP_ID", "")
    app_sha = os.environ.get("INPUT_APP_COMMIT_SHA", "")
    expected_repository = APP_REPOSITORIES.get(app_id)
    if not expected_repository or not SHA.fullmatch(app_sha):
        print("deploy DB gate: EXECUTION ERROR (invalid app or deployment SHA)", file=sys.stderr)
        return 2
    if os.environ.get("GITHUB_REPOSITORY") != expected_repository or os.environ.get("GITHUB_REF") != "refs/heads/main" or os.environ.get("GITHUB_SHA") != app_sha:
        print("deploy DB gate: EXECUTION ERROR (caller repository, ref, or commit mismatch)", file=sys.stderr)
        return 2
    if os.environ.get("DB_TARGET") != "production" or os.environ.get("DB_ENVIRONMENT") != "production-db-check" or os.environ.get("DB_CONNECTION_ROLE") != "reader":
        print("deploy DB gate: EXECUTION ERROR (Reader target configuration mismatch)", file=sys.stderr)
        return 2

    try:
        if remote_main(expected_repository) != app_sha:
            raise GateError("deployment revision is not the current app main commit")
        with tempfile.TemporaryDirectory(prefix="consumer-db-contract-") as temp:
            contracts_dir = Path(temp) / "contracts"
            contract_command = [sys.executable, str(HERE / "verify-consumer-db-contracts.py"), "--validate-only", "--contracts-dir", str(contracts_dir), "--app-id", app_id, "--app-commit", app_sha]
            contract_format = require_success(contract_command, "application contract retrieval/format validation")
            print(contract_format)

            shared_sha = remote_main(SHARED_REPOSITORY)
            clone = Path(temp) / "shared"
            clone.mkdir()
            require_success(["git", "init", "-q", str(clone)], "shared inventory checkout")
            require_success(["git", "-C", str(clone), "fetch", "--quiet", "--depth=1", f"https://github.com/{SHARED_REPOSITORY}.git", shared_sha], "shared inventory fetch")
            require_success(["git", "-C", str(clone), "checkout", "--quiet", "--detach", "FETCH_HEAD"], "shared inventory checkout")
            require_success([sys.executable, str(HERE / "check-migrations.py"), "--repo", str(clone)], "shared migration inventory integrity")
            print(f"shared migration inventory: PASS (main {shared_sha})")

            require_success([sys.executable, str(HERE / "validate-writer-db-env.py")], "Reader connection configuration")
            identity = require_success([sys.executable, str(HERE / "verify-db-project-identity.py")], "Prod DB identity")
            print(identity)

            history_output = Path(temp) / "history-output"
            history_env = os.environ.copy()
            history_env["GITHUB_OUTPUT"] = str(history_output)
            history = run([sys.executable, str(HERE / "check-migration-history.py"), "--migrations-dir", str(clone / "supabase" / "migrations"), "--output", str(history_output)], env=history_env)
            state_lines = history_output.read_text(encoding="utf-8").splitlines() if history_output.exists() else []
            states = [line.removeprefix("state=") for line in state_lines if line.startswith("state=")]
            if history.returncode != 0 or states != ["IN_SYNC"]:
                state = states[-1] if states else "ERROR"
                print(f"shared migration history: {state}", file=sys.stderr)
                raise GateError("shared migration history is not IN_SYNC")
            print("shared migration history: IN_SYNC")

            contract = run([sys.executable, str(HERE / "verify-consumer-db-contracts.py"), "--contracts-dir", str(contracts_dir), "--app-id", app_id, "--app-commit", app_sha])
            if contract.returncode != 0:
                safe_output = "\n".join(line for line in (contract.stdout + contract.stderr).splitlines() if re.match(r"^(price-memo|receipt-manager|DB contract aggregate):", line))
                if safe_output:
                    print(safe_output, file=sys.stderr)
                result_kind = "CONTRACT MISMATCH" if "CONTRACT MISMATCH" in safe_output else "EXECUTION ERROR"
                raise GateError(f"{app_id}: {result_kind} (catalog verification failed, exit {contract.returncode})")
            print(contract.stdout.strip())

            if remote_main(SHARED_REPOSITORY) != shared_sha:
                raise GateError("shared main changed during verification")
            if remote_main(expected_repository) != app_sha:
                raise GateError("app main changed during verification")

        print(f"deploy DB gate: PASS ({app_id} {app_sha})")
        return 0
    except (GateError, OSError) as exc:
        status = "CONTRACT MISMATCH" if "CONTRACT MISMATCH" in str(exc) else "EXECUTION ERROR"
        print(f"deploy DB gate: {status} ({exc})", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
