#!/usr/bin/env python3
"""Require an existing, main-restricted Writer Environment before its job can start."""

from __future__ import annotations

import json
import os
import sys
from urllib.error import URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

API = "https://api.github.com"


class EnvironmentError(Exception):
    pass


def github_get(url: str, token: str) -> dict:
    request = Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "shared-supabase-db-writer-environment-check",
        },
    )
    try:
        with urlopen(request, timeout=15) as response:
            data = json.loads(response.read().decode("utf-8"))
    except (OSError, URLError, TimeoutError, UnicodeError, json.JSONDecodeError):
        raise EnvironmentError("GitHub Environment protection metadata could not be read") from None
    if not isinstance(data, dict):
        raise EnvironmentError("GitHub Environment protection metadata was invalid")
    return data


def validate(environment: dict, branch_policy: dict, target: str) -> str:
    expected_name = {
        "dev": "development-db-apply",
        "production": "production-db-apply",
    }.get(target)
    if expected_name is None or environment.get("name") != expected_name:
        raise EnvironmentError("the expected target Writer Environment does not exist")
    if environment.get("can_admins_bypass") is not False:
        raise EnvironmentError("Writer Environment administrator bypass must be disabled")
    deployment_policy = environment.get("deployment_branch_policy")
    if not isinstance(deployment_policy, dict) or deployment_policy.get("custom_branch_policies") is not True:
        raise EnvironmentError("Writer Environment must use an explicit main-only branch policy")
    policies = branch_policy.get("branch_policies")
    names = sorted(
        policy.get("name", "")
        for policy in policies or []
        if isinstance(policy, dict)
    )
    if names != ["main"]:
        raise EnvironmentError("Writer Environment must allow only the main branch")

    rules = environment.get("protection_rules")
    if not isinstance(rules, list) or not any(
        isinstance(rule, dict) and rule.get("type") == "branch_policy" for rule in rules
    ):
        raise EnvironmentError("Writer Environment branch protection is missing")
    reviewer_rules = [
        rule
        for rule in rules
        if isinstance(rule, dict) and rule.get("type") == "required_reviewers"
    ]
    if target == "production":
        if not reviewer_rules or not any(rule.get("reviewers") for rule in reviewer_rules):
            raise EnvironmentError("production Writer Environment requires at least one reviewer")
        if any(rule.get("prevent_self_review") is True for rule in reviewer_rules):
            return "production Writer Environment protection valid (self-review is prevented)"
        return "production Writer Environment protection valid (reviewer gate allows self-approval)"
    return "Dev Writer Environment protection valid (main-only, administrator bypass disabled)"


def main() -> int:
    target = os.environ.get("DB_TARGET", "")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        print("Writer Environment check: read-only GitHub token is unavailable", file=sys.stderr)
        return 2
    if not repository or target not in {"dev", "production"}:
        print("Writer Environment check: target configuration is invalid", file=sys.stderr)
        return 2
    name = "development-db-apply" if target == "dev" else "production-db-apply"
    encoded_name = quote(name, safe="")
    try:
        environment = github_get(f"{API}/repos/{repository}/environments/{encoded_name}", token)
        policies = github_get(
            f"{API}/repos/{repository}/environments/{encoded_name}/deployment-branch-policies",
            token,
        )
        message = validate(environment, policies, target)
    except EnvironmentError as error:
        print(f"Writer Environment check: {error}", file=sys.stderr)
        return 2
    print(message)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
