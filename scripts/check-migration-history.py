#!/usr/bin/env python3
"""Fail-closed comparison of repository migration versions and remote history."""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
from pathlib import Path

MIGRATION_NAME = re.compile(r"^(\d{14})_[A-Za-z0-9][A-Za-z0-9_-]*\.sql$")
VERSION = re.compile(r"^\d{14}$")
HISTORY_QUERY = (
    "SELECT version FROM supabase_migrations.schema_migrations ORDER BY version;"
)


class CheckError(Exception):
    pass


def local_versions(directory: Path) -> set[str]:
    versions: set[str] = set()
    for path in sorted(directory.glob("*.sql")):
        match = MIGRATION_NAME.fullmatch(path.name)
        if match is None:
            raise CheckError(f"invalid migration filename: {path.name}")
        version = match.group(1)
        if version in versions:
            raise CheckError(f"duplicate local migration version: {version}")
        versions.add(version)
    if not versions:
        raise CheckError("no local SQL migrations found")
    return versions


def parse_remote_versions(output: str) -> set[str]:
    versions: set[str] = set()
    for line in output.splitlines():
        value = line.strip()
        if not VERSION.fullmatch(value):
            raise CheckError("remote migration history contains a malformed version")
        if value in versions:
            raise CheckError(f"remote migration history contains duplicate version: {value}")
        versions.add(value)
    return versions


def query_remote_versions() -> set[str]:
    try:
        result = subprocess.run(
            ["psql", "-X", "-w", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", HISTORY_QUERY],
            check=True,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except (OSError, subprocess.SubprocessError):
        raise CheckError("database connection or migration-history query failed") from None
    return parse_remote_versions(result.stdout)


def check_immutable_migrations(repo: Path, base_ref: str) -> None:
    migrations_dir = repo / "supabase" / "migrations"
    try:
        result = subprocess.run(
            [
                "git",
                "-C",
                str(repo),
                "diff",
                "--name-status",
                "--no-renames",
                base_ref,
                "--",
                "supabase/migrations/",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        raise CheckError("cannot compare migrations with the protected base ref") from None

    changed_sql = [
        line
        for line in result.stdout.splitlines()
        if line and line.split("\t", 1)[-1].endswith(".sql") and not line.startswith("A\t")
    ]
    if changed_sql:
        raise CheckError(
            "existing migration SQL files are immutable; only new migration files may be added"
        )

    untracked = subprocess.run(
        [
            "git",
            "-C",
            str(repo),
            "ls-files",
            "--others",
            "--exclude-standard",
            "--",
            "supabase/migrations/",
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    for relative in untracked.stdout.splitlines():
        if not MIGRATION_NAME.fullmatch(Path(relative).name):
            raise CheckError(f"invalid new migration filename: {Path(relative).name}")

    local_versions(migrations_dir)
    _validate_migration_manifest(migrations_dir)


def _validate_migration_manifest(migrations_dir: Path) -> None:
    manifest_path = migrations_dir / "SHA256SUMS"
    sql_files = {path.name: path for path in migrations_dir.glob("*.sql")}
    expected: dict[str, str] = {}
    try:
        for line in manifest_path.read_text(encoding="utf-8").splitlines():
            match = re.fullmatch(r"([0-9a-f]{64})  (supabase/migrations/([^/]+))", line)
            if match is None:
                raise ValueError
            digest, relative, name = match.groups()
            if relative != f"supabase/migrations/{name}" or name in expected:
                raise ValueError
            expected[name] = digest
    except (OSError, ValueError):
        raise CheckError("migration checksum manifest is missing or malformed") from None

    if set(expected) != set(sql_files):
        raise CheckError("migration checksum manifest does not match SQL files")
    for name, path in sql_files.items():
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if expected[name] != actual:
            raise CheckError(f"migration checksum mismatch: {name}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--migrations-dir", type=Path, default=Path("supabase/migrations"))
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--base-ref", help="also reject edits/deletions/renames from this ref")
    parser.add_argument(
        "--only-immutability",
        action="store_true",
        help="check migration changes against --base-ref without querying history",
    )
    parser.add_argument(
        "--remote-versions-file",
        type=Path,
        help=argparse.SUPPRESS,
    )
    args = parser.parse_args()

    try:
        if args.base_ref:
            check_immutable_migrations(args.repo.resolve(), args.base_ref)
        if args.only_immutability:
            if not args.base_ref:
                raise CheckError("--only-immutability requires --base-ref")
            print("migration immutability check passed")
            return 0
        local = local_versions(args.migrations_dir)
        if args.remote_versions_file:
            remote = parse_remote_versions(args.remote_versions_file.read_text(encoding="utf-8"))
        else:
            remote = query_remote_versions()
    except (CheckError, OSError) as error:
        print(f"migration preflight: ERROR: {error}", file=sys.stderr)
        return 2

    pending = sorted(local - remote)
    remote_only = sorted(remote - local)
    if remote_only:
        print("migration preflight: REMOTE_ONLY: " + ",".join(remote_only), file=sys.stderr)
    if pending:
        print("migration preflight: PENDING: " + ",".join(pending), file=sys.stderr)
    if remote_only:
        return 1
    if pending:
        return 1
    print(f"migration preflight: IN_SYNC ({len(local)} versions)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
