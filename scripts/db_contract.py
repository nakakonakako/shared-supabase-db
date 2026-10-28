#!/usr/bin/env python3
"""Strict v1 DB contract parsing and read-only PostgreSQL catalog checks."""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class ContractError(ValueError):
    """Invalid or unsupported contract input."""


class VerificationError(RuntimeError):
    """Connection or unexpected catalog verifier failure."""


APP_ID = re.compile(r"^[a-z][a-z0-9-]{1,62}$")
IDENTIFIER = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")
FUNCTION = re.compile(r"^(?:[a-z_][a-z0-9_]*\.)+[a-z_][a-z0-9_]*\([^;]*\)$")
SHA = re.compile(r"^[0-9a-f]{40,64}$")
CONTRACT_KEYS = {"format_version", "app_id", "contract_version", "capabilities"}
CAPABILITY_KEYS = {"tables", "functions", "auth", "realtime"}
TABLE_KEYS = {"schema", "name", "columns", "constraints", "rls", "privileges", "triggers"}
COLUMN_KEYS = {"name", "type", "nullable"}
CONSTRAINT_KEYS = {"kind", "columns", "references", "on_delete"}
FK_KEYS = {"table", "columns"}
RLS_KEYS = {"enabled", "forced", "policies"}
POLICY_KEYS = {"name", "command", "roles"}
PRIVILEGE_KEYS = {"role", "allow", "deny"}
TRIGGER_KEYS = {"name", "enabled"}
FUNCTION_KEYS = {"signature", "returns", "security", "search_path", "execute"}
DEPENDENCY_KEYS = {"functions", "foreign_keys"}
REALTIME_KEYS = {"relations", "functions", "triggers"}
REALTIME_RELATION_KEYS = {"schema", "name", "rls_enabled"}
ROLE_NAME = re.compile(r"^(?:public|[a-z_][a-z0-9_]{0,62})$")
PRIVILEGES = {"SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER"}
POLICY_COMMANDS = {"ALL", "SELECT", "INSERT", "UPDATE", "DELETE"}
TRIGGER_STATES = {"enabled", "disabled", "replica", "always"}


def _object(value: Any, label: str, allowed: set[str], required: set[str]) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be an object")
    unknown = set(value) - allowed
    missing = required - set(value)
    if unknown:
        raise ContractError(f"{label} has unsupported fields: {', '.join(sorted(unknown))}")
    if missing:
        raise ContractError(f"{label} is missing fields: {', '.join(sorted(missing))}")
    return value


def _array(value: Any, label: str, *, nonempty: bool = False) -> list[Any]:
    if not isinstance(value, list) or (nonempty and not value):
        raise ContractError(f"{label} must be {'a non-empty ' if nonempty else 'an '}array")
    return value


def _identifier(value: Any, label: str) -> str:
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        raise ContractError(f"{label} must be a lowercase PostgreSQL identifier")
    return value


def _strings(value: Any, label: str, pattern: re.Pattern[str] | None = None) -> list[str]:
    items = _array(value, label, nonempty=True)
    if any(not isinstance(item, str) or (pattern and not pattern.fullmatch(item)) for item in items):
        raise ContractError(f"{label} contains an invalid value")
    if len(items) != len(set(items)):
        raise ContractError(f"{label} contains duplicates")
    return items


def _string_array(value: Any, label: str, pattern: re.Pattern[str] | None = None) -> list[str]:
    if not isinstance(value, list):
        raise ContractError(f"{label} must be an array")
    return _strings(value, label, pattern) if value else []


def _enum(value: Any, label: str, choices: set[str]) -> str:
    if not isinstance(value, str) or value not in choices:
        raise ContractError(f"{label} is unsupported")
    return value


def validate_contract(data: Any) -> dict[str, Any]:
    """Validate the complete supported v1 subset; reject unknown semantics."""
    contract = _object(data, "contract", CONTRACT_KEYS, CONTRACT_KEYS)
    if contract["format_version"] != 1 or isinstance(contract["format_version"], bool):
        raise ContractError("format_version must be the supported integer 1")
    if not isinstance(contract["app_id"], str) or not APP_ID.fullmatch(contract["app_id"]):
        raise ContractError("app_id must be a lowercase kebab-case identifier")
    if not isinstance(contract["contract_version"], str) or not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", contract["contract_version"]):
        raise ContractError("contract_version must use MAJOR.MINOR.PATCH syntax")

    caps = _object(contract["capabilities"], "capabilities", CAPABILITY_KEYS, {"tables", "functions"})
    tables = _array(caps["tables"], "capabilities.tables")
    functions = _array(caps["functions"], "capabilities.functions")
    seen_tables: set[tuple[str, str]] = set()
    for index, raw_table in enumerate(tables):
        label = f"tables[{index}]"
        table = _object(raw_table, label, TABLE_KEYS, {"schema", "name", "columns"})
        for optional_array in ("constraints", "privileges", "triggers"):
            _array(table.get(optional_array, []), f"{label}.{optional_array}")
        schema, name = _identifier(table["schema"], f"{label}.schema"), _identifier(table["name"], f"{label}.name")
        if (schema, name) in seen_tables:
            raise ContractError(f"{label} duplicates a table")
        seen_tables.add((schema, name))
        columns = _array(table["columns"], f"{label}.columns", nonempty=True)
        seen_columns: set[str] = set()
        for col_index, raw_col in enumerate(columns):
            col_label = f"{label}.columns[{col_index}]"
            col = _object(raw_col, col_label, COLUMN_KEYS, COLUMN_KEYS)
            col_name = _identifier(col["name"], f"{col_label}.name")
            if col_name in seen_columns:
                raise ContractError(f"{col_label} duplicates a column")
            seen_columns.add(col_name)
            if not isinstance(col["type"], str) or not col["type"] or any(ch in col["type"] for ch in ";'\n\r"):
                raise ContractError(f"{col_label}.type must be a simple PostgreSQL format_type value")
            if not isinstance(col["nullable"], bool):
                raise ContractError(f"{col_label}.nullable must be boolean")

        for c_index, raw_constraint in enumerate(table.get("constraints", [])):
            c_label = f"{label}.constraints[{c_index}]"
            constraint = _object(raw_constraint, c_label, CONSTRAINT_KEYS, {"kind", "columns"})
            _enum(constraint["kind"], f"{c_label}.kind", {"primary_key", "unique", "foreign_key"})
            cols = _strings(constraint["columns"], f"{c_label}.columns", IDENTIFIER)
            if not set(cols) <= seen_columns:
                raise ContractError(f"{c_label} references an undeclared required column")
            if constraint["kind"] == "foreign_key":
                ref = _object(constraint.get("references"), f"{c_label}.references", FK_KEYS, FK_KEYS)
                _qualified_table(ref["table"], f"{c_label}.references.table")
                _strings(ref["columns"], f"{c_label}.references.columns", IDENTIFIER)
                if len(ref["columns"]) != len(cols):
                    raise ContractError(f"{c_label} local and referenced column counts differ")
                _enum(constraint.get("on_delete", "no_action"), f"{c_label}.on_delete", {"no_action", "restrict", "cascade", "set_null", "set_default"})
            elif "references" in constraint or "on_delete" in constraint:
                raise ContractError(f"{c_label} has FK-only fields on a non-FK constraint")

        if "rls" in table:
            rls = _object(table["rls"], f"{label}.rls", RLS_KEYS, {"enabled"})
            _array(rls.get("policies", []), f"{label}.rls.policies")
            if not isinstance(rls["enabled"], bool) or ("forced" in rls and not isinstance(rls["forced"], bool)):
                raise ContractError(f"{label}.rls enabled/forced values must be boolean")
            for p_index, raw_policy in enumerate(rls.get("policies", [])):
                p_label = f"{label}.rls.policies[{p_index}]"
                policy = _object(raw_policy, p_label, POLICY_KEYS, POLICY_KEYS)
                _identifier(policy["name"], f"{p_label}.name")
                _enum(policy["command"], f"{p_label}.command", POLICY_COMMANDS)
                _strings(policy["roles"], f"{p_label}.roles", ROLE_NAME)

        for p_index, raw_privilege in enumerate(table.get("privileges", [])):
            p_label = f"{label}.privileges[{p_index}]"
            privilege = _object(raw_privilege, p_label, PRIVILEGE_KEYS, {"role", "allow", "deny"})
            if not isinstance(privilege["role"], str) or not ROLE_NAME.fullmatch(privilege["role"]):
                raise ContractError(f"{p_label}.role is invalid")
            allow = _string_array(privilege["allow"], f"{p_label}.allow")
            deny = _string_array(privilege["deny"], f"{p_label}.deny")
            if set(allow + deny) - PRIVILEGES or set(allow) & set(deny):
                raise ContractError(f"{p_label} has unsupported or contradictory privileges")

        for t_index, raw_trigger in enumerate(table.get("triggers", [])):
            t_label = f"{label}.triggers[{t_index}]"
            trigger = _object(raw_trigger, t_label, TRIGGER_KEYS, TRIGGER_KEYS)
            _identifier(trigger["name"], f"{t_label}.name")
            _enum(trigger["enabled"], f"{t_label}.enabled", TRIGGER_STATES)

    seen_functions: set[str] = set()
    for index, raw_function in enumerate(functions):
        label = f"functions[{index}]"
        function = _object(raw_function, label, FUNCTION_KEYS, {"signature", "returns", "security", "execute"})
        if not isinstance(function["signature"], str) or not FUNCTION.fullmatch(function["signature"]):
            raise ContractError(f"{label}.signature must be schema.name(argtypes)")
        if function["signature"] in seen_functions:
            raise ContractError(f"{label} duplicates a function")
        seen_functions.add(function["signature"])
        if not isinstance(function["returns"], str) or not function["returns"] or any(ch in function["returns"] for ch in ";'\n\r"):
            raise ContractError(f"{label}.returns is invalid")
        _enum(function["security"], f"{label}.security", {"invoker", "definer"})
        if "search_path" in function and not isinstance(function["search_path"], str):
            raise ContractError(f"{label}.search_path must be a string")
        _object(function["execute"], f"{label}.execute", {"allow", "deny"}, {"allow", "deny"})
        for field in ("allow", "deny"):
            _string_array(function["execute"][field], f"{label}.execute.{field}", ROLE_NAME)

    for section in ("auth", "realtime"):
        if section not in caps:
            continue
        if section == "auth":
            dep = _object(caps[section], "capabilities.auth", DEPENDENCY_KEYS, set())
            _array(dep.get("foreign_keys", []), "auth.foreign_keys")
            _array(dep.get("functions", []), "auth.functions")
            for fk_index, raw_fk in enumerate(dep.get("foreign_keys", [])):
                label = f"auth.foreign_keys[{fk_index}]"
                fk = _object(raw_fk, label, {"table", "columns", "references", "referenced_columns", "on_delete"}, {"table", "columns", "references"})
                _qualified_table(fk["table"], f"{label}.table")
                _strings(fk["columns"], f"{label}.columns", IDENTIFIER)
                _qualified_table(fk["references"], f"{label}.references")
                _strings(fk.get("referenced_columns", ["id"]), f"{label}.referenced_columns", IDENTIFIER)
                if fk["references"] != "auth.users":
                    raise ContractError(f"{label}.references must be auth.users in v1")
                _enum(fk.get("on_delete", "no_action"), f"{label}.on_delete", {"no_action", "restrict", "cascade", "set_null", "set_default"})
            _check_dependency_functions(dep, "auth")
        else:
            dep = _object(caps[section], "capabilities.realtime", REALTIME_KEYS, set())
            _array(dep.get("relations", []), "realtime.relations")
            _array(dep.get("functions", []), "realtime.functions")
            _array(dep.get("triggers", []), "realtime.triggers")
            for r_index, raw_relation in enumerate(dep.get("relations", [])):
                label = f"realtime.relations[{r_index}]"
                relation = _object(raw_relation, label, REALTIME_RELATION_KEYS, REALTIME_RELATION_KEYS)
                _identifier(relation["schema"], f"{label}.schema")
                _identifier(relation["name"], f"{label}.name")
                if not isinstance(relation["rls_enabled"], bool):
                    raise ContractError(f"{label}.rls_enabled must be boolean")
            _check_dependency_functions(dep, "realtime")
            for t_index, raw_trigger in enumerate(dep.get("triggers", [])):
                label = f"realtime.triggers[{t_index}]"
                trigger = _object(raw_trigger, label, {"table", "name", "enabled"}, {"table", "name", "enabled"})
                _qualified_table(trigger["table"], f"{label}.table")
                _identifier(trigger["name"], f"{label}.name")
                _enum(trigger["enabled"], f"{label}.enabled", TRIGGER_STATES)
    return contract


def _qualified_table(value: Any, label: str) -> tuple[str, str]:
    if not isinstance(value, str) or value.count(".") != 1:
        raise ContractError(f"{label} must be schema.table")
    schema, name = value.split(".")
    return _identifier(schema, label), _identifier(name, label)


def _check_dependency_functions(dep: dict[str, Any], section: str) -> None:
    for index, signature in enumerate(_array(dep.get("functions", []), f"{section}.functions")):
        if not isinstance(signature, str) or not FUNCTION.fullmatch(signature):
            raise ContractError(f"{section}.functions[{index}] must be schema.name(argtypes)")


def load_contract(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError("contract file could not be read as UTF-8 JSON") from exc
    return validate_contract(data)


def _literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def _name_array(names: list[str]) -> str:
    return "ARRAY[" + ",".join(_literal(name) for name in names) + "]::name[]"


def _column_check(schema: str, table: str, column: dict[str, Any]) -> str:
    nullable = "NOT a.attnotnull" if column["nullable"] else "a.attnotnull"
    return f"""EXISTS (
      SELECT 1 FROM pg_catalog.pg_attribute a
      JOIN pg_catalog.pg_class c ON c.oid=a.attrelid
      JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname={_literal(schema)} AND c.relname={_literal(table)}
        AND a.attname={_literal(column['name'])} AND a.attnum > 0 AND NOT a.attisdropped
        AND pg_catalog.format_type(a.atttypid,a.atttypmod)={_literal(column['type'])}
        AND {nullable}
    )"""


def _constraint_check(schema: str, table: str, spec: dict[str, Any]) -> str:
    kind = {"primary_key": "p", "unique": "u", "foreign_key": "f"}[spec["kind"]]
    cols = _name_array(spec["columns"])
    local_cols = "ARRAY(SELECT a.attname FROM unnest(c.conkey) WITH ORDINALITY k(attnum,ord) JOIN pg_catalog.pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum ORDER BY k.ord)::name[]"
    predicates = [f"c.contype={_literal(kind)}", f"n.nspname={_literal(schema)}", f"t.relname={_literal(table)}", f"{local_cols}={cols}"]
    if spec["kind"] == "foreign_key":
        ref_schema, ref_table = _qualified_table(spec["references"]["table"], "references.table")
        ref_cols = _name_array(spec["references"]["columns"])
        remote_cols = "ARRAY(SELECT a.attname FROM unnest(c.confkey) WITH ORDINALITY k(attnum,ord) JOIN pg_catalog.pg_attribute a ON a.attrelid=c.confrelid AND a.attnum=k.attnum ORDER BY k.ord)::name[]"
        predicates.extend([f"rn.nspname={_literal(ref_schema)}", f"rt.relname={_literal(ref_table)}", f"{remote_cols}={ref_cols}"])
        delete_code = {"no_action": "a", "restrict": "r", "cascade": "c", "set_null": "n", "set_default": "d"}[spec.get("on_delete", "no_action")]
        predicates.append(f"c.confdeltype={_literal(delete_code)}")
        joins = "JOIN pg_catalog.pg_class rt ON rt.oid=c.confrelid JOIN pg_catalog.pg_namespace rn ON rn.oid=rt.relnamespace"
    else:
        joins = ""
    return f"EXISTS (SELECT 1 FROM pg_catalog.pg_constraint c JOIN pg_catalog.pg_class t ON t.oid=c.conrelid JOIN pg_catalog.pg_namespace n ON n.oid=t.relnamespace {joins} WHERE {' AND '.join(predicates)})"


def _policy_check(schema: str, table: str, policy: dict[str, Any]) -> str:
    roles = _name_array(policy["roles"])
    command = policy["command"]
    return f"""EXISTS (
      SELECT 1 FROM pg_catalog.pg_policies p
      WHERE p.schemaname={_literal(schema)} AND p.tablename={_literal(table)}
        AND p.policyname={_literal(policy['name'])} AND p.cmd={_literal(command)}
        AND ARRAY(SELECT unnest(p.roles) ORDER BY 1) = ARRAY(SELECT unnest({roles}) ORDER BY 1)
    )"""


def _privilege_check(schema: str, table: str, entry: dict[str, Any], privilege: str, expected: bool) -> str:
    rel = f"{schema}.{table}"
    return f"pg_catalog.has_table_privilege({_literal(entry['role'])},{_literal(rel)},{_literal(privilege)}) IS {'TRUE' if expected else 'FALSE'}"


def _function_check(spec: dict[str, Any]) -> list[tuple[str, str]]:
    signature = spec["signature"]
    fn = f"pg_catalog.to_regprocedure({_literal(signature)})"
    checks = [(f"function {signature} exists", f"{fn} IS NOT NULL")]
    checks.append((f"function {signature} return type", f"EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.oid={fn} AND pg_catalog.format_type(p.prorettype,NULL)={_literal(spec['returns'])})"))
    checks.append((f"function {signature} security mode", f"EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.oid={fn} AND p.prosecdef IS {'TRUE' if spec['security']=='definer' else 'FALSE'})"))
    if "search_path" in spec:
        expected = "ARRAY['search_path=\"\"']::text[]" if spec["search_path"] == "" else f"ARRAY[{_literal('search_path=' + spec['search_path'])}]::text[]"
        checks.append((f"function {signature} search_path", f"EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.oid={fn} AND p.proconfig={expected})"))
    for role in spec["execute"]["allow"]:
        checks.append((f"function {signature} EXECUTE for {role}", f"pg_catalog.has_function_privilege({_literal(role)},{fn},'EXECUTE') IS TRUE"))
    for role in spec["execute"]["deny"]:
        checks.append((f"function {signature} EXECUTE denied for {role}", f"pg_catalog.has_function_privilege({_literal(role)},{fn},'EXECUTE') IS FALSE"))
    return checks


def build_checks(contract: dict[str, Any]) -> list[tuple[str, str]]:
    """Build named SQL boolean assertions using catalog metadata only."""
    checks: list[tuple[str, str]] = []
    caps = contract["capabilities"]
    for table in caps["tables"]:
        schema, name = table["schema"], table["name"]
        qualified = f"{schema}.{name}"
        checks.append((f"table {qualified} exists", f"pg_catalog.to_regclass({_literal(qualified)}) IS NOT NULL"))
        for col in table["columns"]:
            checks.append((f"column {qualified}.{col['name']} type/nullability", _column_check(schema, name, col)))
        for constraint in table.get("constraints", []):
            checks.append((f"constraint {qualified} {constraint['kind']}({','.join(constraint['columns'])})", _constraint_check(schema, name, constraint)))
        if "rls" in table:
            rls = table["rls"]
            checks.append((f"table {qualified} RLS enabled", f"EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname={_literal(schema)} AND c.relname={_literal(name)} AND c.relrowsecurity IS {'TRUE' if rls['enabled'] else 'FALSE'})"))
            if "forced" in rls:
                checks.append((f"table {qualified} FORCE RLS", f"EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname={_literal(schema)} AND c.relname={_literal(name)} AND c.relforcerowsecurity IS {'TRUE' if rls['forced'] else 'FALSE'})"))
            for policy in rls.get("policies", []):
                checks.append((f"policy {qualified}.{policy['name']}", _policy_check(schema, name, policy)))
        for entry in table.get("privileges", []):
            for privilege in entry["allow"]:
                checks.append((f"table {qualified} {entry['role']} {privilege} allowed", _privilege_check(schema, name, entry, privilege, True)))
            for privilege in entry["deny"]:
                checks.append((f"table {qualified} {entry['role']} {privilege} denied", _privilege_check(schema, name, entry, privilege, False)))
        for trigger in table.get("triggers", []):
            checks.append((f"trigger {qualified}.{trigger['name']} enabled={trigger['enabled']}", _trigger_check(schema, name, trigger)))
    for function in caps["functions"]:
        checks.extend(_function_check(function))
    for fk in caps.get("auth", {}).get("foreign_keys", []):
        local_schema, local_table = _qualified_table(fk["table"], "auth.foreign_keys.table")
        ref_schema, ref_table = _qualified_table(fk["references"], "auth.foreign_keys.references")
        spec = {"kind": "foreign_key", "columns": fk["columns"], "references": {"table": f"{ref_schema}.{ref_table}", "columns": fk.get("referenced_columns", ["id"])}, "on_delete": fk.get("on_delete", "no_action")}
        checks.append((f"Auth FK {fk['table']} -> {fk['references']}", _constraint_check(local_schema, local_table, spec)))
    for section in ("auth", "realtime"):
        dep = caps.get(section, {})
        for signature in dep.get("functions", []):
            checks.append((f"{section} function {signature} exists", f"pg_catalog.to_regprocedure({_literal(signature)}) IS NOT NULL"))
    for relation in caps.get("realtime", {}).get("relations", []):
        schema, name = relation["schema"], relation["name"]
        checks.append((f"Realtime relation {schema}.{name} exists", f"pg_catalog.to_regclass({_literal(f'{schema}.{name}')}) IS NOT NULL"))
        checks.append((f"Realtime relation {schema}.{name} RLS", f"EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname={_literal(schema)} AND c.relname={_literal(name)} AND c.relrowsecurity IS {'TRUE' if relation['rls_enabled'] else 'FALSE'})"))
    for trigger in caps.get("realtime", {}).get("triggers", []):
        schema, name = _qualified_table(trigger["table"], "realtime.triggers.table")
        checks.append((f"Realtime trigger {schema}.{name}.{trigger['name']}", _trigger_check(schema, name, trigger)))
    return checks


def _trigger_check(schema: str, table: str, trigger: dict[str, Any]) -> str:
    state = {"enabled": "O", "disabled": "D", "replica": "R", "always": "A"}[trigger["enabled"]]
    return f"EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname={_literal(schema)} AND c.relname={_literal(table)} AND t.tgname={_literal(trigger['name'])} AND t.tgenabled={_literal(state)} AND NOT t.tgisinternal)"


@dataclass(frozen=True)
class CheckResult:
    label: str
    passed: bool


def verify_catalog(contract: dict[str, Any], *, psql: str = "psql", env: dict[str, str] | None = None) -> list[CheckResult]:
    checks = build_checks(contract)
    if not checks:
        raise VerificationError("contract contains no catalog assertions")
    rows = ",\n".join(f"({index}, {_literal(label)}, ({predicate}))" for index, (label, predicate) in enumerate(checks))
    sql = (
        "BEGIN TRANSACTION READ ONLY; SET LOCAL statement_timeout='30s'; "
        "SELECT CASE WHEN passed THEN 't' ELSE 'f' END FROM (VALUES\n"
        f"{rows}\n) AS contract_checks(ord, label, passed) ORDER BY ord; COMMIT;"
    )
    try:
        process = subprocess.run(
            [psql, "-X", "-w", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", sql],
            capture_output=True, text=True, check=False, timeout=45, env=env,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise VerificationError("PostgreSQL contract verification could not execute") from exc
    outputs = process.stdout.splitlines()
    if process.returncode != 0 or len(outputs) != len(checks) or any(value not in {"t", "f"} for value in outputs):
        raise VerificationError("PostgreSQL contract verification failed or returned an unexpected result")
    return [CheckResult(label, value == "t") for (label, _), value in zip(checks, outputs, strict=True)]
