"""Fetch and validate the explicitly pinned consumer DB contracts."""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

from db_contract import ContractError, validate_contract


@dataclass(frozen=True)
class ConsumerContract:
    app_id: str
    repository: str
    path: str
    commit: str


CONTRACTS = (
    ConsumerContract(
        "price-memo",
        "nakakonakako/price-memo",
        "db-contracts/price-memo.json",
        "7620cc8e43ef1defeaa0700d6ad0d509097ae52d",
    ),
    ConsumerContract(
        "receipt-manager",
        "nakakonakako/receipt-manager",
        "db-contracts/receipt-manager.json",
        "2c6803cdd7dbc31d441c822df23027f2ddc3f6ce",
    ),
)
SHA = re.compile(r"^[0-9a-f]{40}$")
GITHUB_API = "https://api.github.com"


class ContractFetchError(RuntimeError):
    """A pinned contract could not be safely fetched and validated."""


def _request(url: str) -> bytes:
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/vnd.github+json", "User-Agent": "shared-supabase-db-contract-check"},
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.read(1_000_001)
    except (OSError, urllib.error.URLError, TimeoutError) as exc:
        raise ContractFetchError("pinned contract source could not be fetched") from exc


def fetch_contract(spec: ConsumerContract) -> dict[str, Any]:
    if not SHA.fullmatch(spec.commit):
        raise ContractFetchError("pinned contract revision is not a full 40-character commit SHA")

    commit_url = f"{GITHUB_API}/repos/{spec.repository}/commits/{spec.commit}"
    try:
        commit_data = json.loads(_request(commit_url))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ContractFetchError("pinned contract revision response is invalid") from exc
    if not isinstance(commit_data, dict) or commit_data.get("sha") != spec.commit:
        raise ContractFetchError("pinned contract revision did not match the requested commit SHA")

    raw_url = f"https://raw.githubusercontent.com/{spec.repository}/{spec.commit}/{spec.path}"
    payload = _request(raw_url)
    if len(payload) > 1_000_000:
        raise ContractFetchError("pinned contract exceeds the allowed size")
    try:
        data = json.loads(payload)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ContractFetchError("pinned contract is not valid UTF-8 JSON") from exc
    try:
        contract = validate_contract(data)
    except ContractError as exc:
        raise ContractFetchError("pinned contract format is unsupported or invalid") from exc
    if contract["app_id"] != spec.app_id:
        raise ContractFetchError("pinned contract app_id does not match its repository")
    return contract


def fetch_all_contracts() -> list[tuple[ConsumerContract, dict[str, Any]]]:
    """Fetch both contracts before returning, so callers can connect only after validation."""
    return [(spec, fetch_contract(spec)) for spec in CONTRACTS]
