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
    if (
        not isinstance(deployment_policy, dict)
        or type(deployment_policy.get("custom_branch_policies")) is not bool
        or deployment_policy.get("custom_branch_policies") is not True
        or type(deployment_policy.get("protected_branches")) is not bool
        or deployment_policy.get("protected_branches") is not False
    ):
        raise EnvironmentError("Writer Environment must use an explicit main-only branch policy")
    policies = branch_policy.get("branch_policies")
    total_count = branch_policy.get("total_count")
    if (
        type(total_count) is not int
        or not isinstance(policies, list)
        or total_count != len(policies)
        or total_count != 1
    ):
        raise EnvironmentError("Writer Environment branch policy response is incomplete or unexpected")
    policy = policies[0]
    if (
        not isinstance(policy, dict)
        or type(policy.get("id")) is not int
        or policy.get("name") != "main"
        or policy.get("type") != "branch"
    ):
        raise EnvironmentError("Writer Environment must allow only the main branch")

    rules = environment.get("protection_rules")
    if not isinstance(rules, list) or any(not isinstance(rule, dict) for rule in rules):
        raise EnvironmentError("Writer Environment protection metadata is incomplete")
    if any(rule.get("type") not in {"branch_policy", "required_reviewers"} for rule in rules):
        raise EnvironmentError("Writer Environment contains an unsupported protection rule")
    if any(type(rule.get("id")) is not int for rule in rules):
        raise EnvironmentError("Writer Environment protection metadata is incomplete")
    if len({rule["id"] for rule in rules}) != len(rules):
        raise EnvironmentError("Writer Environment protection metadata is inconsistent")
    branch_rules = [rule for rule in rules if rule.get("type") == "branch_policy"]
    if len(branch_rules) != 1 or type(branch_rules[0].get("id")) is not int:
        raise EnvironmentError("Writer Environment branch protection is missing")
    reviewer_rules = [
        rule
        for rule in rules
        if isinstance(rule, dict) and rule.get("type") == "required_reviewers"
    ]
    if any(
        not isinstance(rule.get("reviewers"), list)
        or type(rule.get("prevent_self_review")) is not bool
        for rule in reviewer_rules
    ):
        raise EnvironmentError("Writer reviewer protection metadata is incomplete")
    if any(
        not isinstance(reviewer, dict)
        or reviewer.get("type") not in {"User", "Team"}
        or not isinstance(reviewer.get("reviewer"), dict)
        or type(reviewer["reviewer"].get("id")) is not int
        or reviewer["reviewer"].get("type", reviewer["type"]) != reviewer["type"]
        or (
            reviewer["type"] == "User"
            and (not isinstance(reviewer["reviewer"].get("login"), str) or not reviewer["reviewer"]["login"])
        )
        or (
            reviewer["type"] == "Team"
            and not any(
                isinstance(reviewer["reviewer"].get(key), str) and reviewer["reviewer"][key]
                for key in ("slug", "name")
            )
        )
        for rule in reviewer_rules
        for reviewer in rule["reviewers"]
    ):
        raise EnvironmentError("Writer reviewer metadata is incomplete")
    if target == "dev":
        if not reviewer_rules or not any(rule["reviewers"] for rule in reviewer_rules):
            raise EnvironmentError("Dev Writer Environment requires at least one reviewer")
        if not any(rule["reviewers"] and rule["prevent_self_review"] is False for rule in reviewer_rules):
            raise EnvironmentError("Dev Writer Environment must allow self-approval")
        return "Dev Writer Environment protection valid (main-only, reviewer approval, self-approval allowed)"
    if target == "production":
        if not reviewer_rules or not any(rule["reviewers"] for rule in reviewer_rules):
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
