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
TABLE_KEYS = {"schema", "name", "relation_kind", "columns", "constraints", "rls", "privileges", "triggers"}
COLUMN_KEYS = {"name", "type", "nullable"}
CONSTRAINT_KEYS = {"kind", "columns", "references", "on_delete", "validated", "set_null_columns"}
FK_KEYS = {"table", "columns"}
RLS_KEYS = {"enabled", "forced", "policies"}
POLICY_KEYS = {"name", "command", "roles"}
PRIVILEGE_KEYS = {"role", "allow", "deny"}
TRIGGER_KEYS = {"name", "enabled"}
FUNCTION_KEYS = {"signature", "returns", "returns_set", "arguments", "security", "search_path", "execute"}
ARGUMENT_KEYS = {"name", "mode", "type"}
DEPENDENCY_KEYS = {"functions", "foreign_keys"}
REALTIME_KEYS = {"relations", "functions", "triggers"}
REALTIME_RELATION_KEYS = {"schema", "name", "rls_enabled"}
ROLE_NAME = re.compile(r"^(?:public|[a-z_][a-z0-9_]{0,62})$")
PRIVILEGES = {"SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER", "MAINTAIN"}
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
        if "relation_kind" in table:
            _enum(table["relation_kind"], f"{label}.relation_kind", {"table", "partitioned_table", "view", "materialized_view"})
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
                if "set_null_columns" in constraint:
                    set_null_columns = _strings(constraint["set_null_columns"], f"{c_label}.set_null_columns", IDENTIFIER)
                    if constraint.get("on_delete", "no_action") != "set_null":
                        raise ContractError(f"{c_label}.set_null_columns requires on_delete=set_null")
                    if not set(set_null_columns) <= set(cols):
                        raise ContractError(f"{c_label}.set_null_columns must be a subset of FK columns")
                    if set(set_null_columns) == set(cols) and set_null_columns != cols:
                        raise ContractError(f"{c_label}.set_null_columns must follow FK column order when listing all columns")
                if "validated" in constraint and not isinstance(constraint["validated"], bool):
                    raise ContractError(f"{c_label}.validated must be boolean")
            elif any(key in constraint for key in ("references", "on_delete", "validated", "set_null_columns")):
                raise ContractError(f"{c_label} has FK-only fields on a non-FK constraint")

        if "rls" in table:
            rls = _object(table["rls"], f"{label}.rls", RLS_KEYS, {"enabled"})
            _array(rls.get("policies", []), f"{label}.rls.policies")
            if not isinstance(rls["enabled"], bool) or ("forced" in rls and not isinstance(rls["forced"], bool)):
                raise ContractError(f"{label}.rls enabled/forced values must be boolean")
            for p_index, raw_policy in enumerate(rls.get("policies", [])):
                p_label = f"{label}.rls.policies[{p_index}]"
                policy = _object(raw_policy, p_label, POLICY_KEYS, POLICY_KEYS)
                _policy_name(policy["name"], f"{p_label}.name")
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
        if "returns_set" in function and not isinstance(function["returns_set"], bool):
            raise ContractError(f"{label}.returns_set must be boolean")
        if function["returns"] == "record" and "arguments" not in function:
            raise ContractError(f"{label}.arguments is required to verify a record return shape")
        if "arguments" in function:
            arguments = _array(function["arguments"], f"{label}.arguments")
            for arg_index, raw_argument in enumerate(arguments):
                arg_label = f"{label}.arguments[{arg_index}]"
                argument = _object(raw_argument, arg_label, ARGUMENT_KEYS, ARGUMENT_KEYS)
                if argument["name"] is not None:
                    _identifier(argument["name"], f"{arg_label}.name")
                _enum(argument["mode"], f"{arg_label}.mode", {"IN", "OUT", "INOUT", "VARIADIC", "TABLE"})
                if not isinstance(argument["type"], str) or not argument["type"] or any(ch in argument["type"] for ch in ";'\n\r"):
                    raise ContractError(f"{arg_label}.type is invalid")
            if function["returns"] == "record" and not any(argument["mode"] in {"OUT", "TABLE"} for argument in arguments):
                raise ContractError(f"{label}.record return requires declared OUT/TABLE columns")
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
                fk = _object(raw_fk, label, {"table", "columns", "references", "referenced_columns", "on_delete", "validated", "set_null_columns"}, {"table", "columns", "references"})
                _qualified_table(fk["table"], f"{label}.table")
                _strings(fk["columns"], f"{label}.columns", IDENTIFIER)
                _qualified_table(fk["references"], f"{label}.references")
                _strings(fk.get("referenced_columns", ["id"]), f"{label}.referenced_columns", IDENTIFIER)
                if fk["references"] != "auth.users":
                    raise ContractError(f"{label}.references must be auth.users in v1")
                _enum(fk.get("on_delete", "no_action"), f"{label}.on_delete", {"no_action", "restrict", "cascade", "set_null", "set_default"})
                if "set_null_columns" in fk:
                    set_null_columns = _strings(fk["set_null_columns"], f"{label}.set_null_columns", IDENTIFIER)
                    if fk.get("on_delete", "no_action") != "set_null" or not set(set_null_columns) <= set(fk["columns"]):
                        raise ContractError(f"{label}.set_null_columns must be a subset of columns with on_delete=set_null")
                    if set(set_null_columns) == set(fk["columns"]) and set_null_columns != fk["columns"]:
                        raise ContractError(f"{label}.set_null_columns must follow FK column order when listing all columns")
                if "validated" in fk and not isinstance(fk["validated"], bool):
                    raise ContractError(f"{label}.validated must be boolean")
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


def _utf8_text(value: str) -> str:
    """Render arbitrary UTF-8 text without embedding it in SQL source."""
    return f"pg_catalog.convert_from(pg_catalog.decode('{value.encode('utf-8').hex()}','hex'),'UTF8')"


def _policy_name(value: Any, label: str) -> str:
    # PostgreSQL identifiers are limited to NAMEDATALEN - 1 bytes (63 by default).
    # pg_policies exposes the stored, possibly quoted identifier as text.
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ContractError(f"{label} must be a non-empty PostgreSQL identifier")
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise ContractError(f"{label} must be valid UTF-8") from exc
    if len(encoded) > 63:
        raise ContractError(f"{label} exceeds PostgreSQL's 63-byte identifier limit")
    return value


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
        predicates.append(f"c.convalidated IS {'TRUE' if spec.get('validated', True) else 'FALSE'}")
        if "set_null_columns" in spec:
            set_null_columns = spec["set_null_columns"]
            if set_null_columns == spec["columns"]:
                predicates.append("c.confdelsetcols IS NULL")
            else:
                set_null_cols = "ARRAY(SELECT a.attname FROM unnest(c.confdelsetcols) WITH ORDINALITY k(attnum,ord) JOIN pg_catalog.pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum ORDER BY a.attname)::name[]"
                predicates.append(f"{set_null_cols}={_name_array(sorted(set_null_columns))}")
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
        AND p.policyname={_utf8_text(policy['name'])} AND p.cmd={_literal(command)}
        AND ARRAY(SELECT unnest(p.roles) ORDER BY 1) = ARRAY(SELECT unnest({roles}) ORDER BY 1)
    )"""


def _privilege_check(schema: str, table: str, entry: dict[str, Any], privilege: str, expected: bool) -> str:
    role = entry["role"]
    relation = "pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace"
    relation_filter = f"n.nspname={_literal(schema)} AND c.relname={_literal(table)}"
    if role == "public":
        granted = f"EXISTS (SELECT 1 FROM {relation} CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(c.relacl, pg_catalog.acldefault('r', c.relowner))) AS acl WHERE {relation_filter} AND acl.grantee=0 AND acl.privilege_type={_literal(privilege)})"
        return f"({granted}) IS {'TRUE' if expected else 'FALSE'}"

    role_exists = f"EXISTS (SELECT 1 FROM pg_catalog.pg_roles r WHERE r.rolname={_literal(role)})"
    granted = f"EXISTS (SELECT 1 FROM {relation} JOIN pg_catalog.pg_roles r ON r.rolname={_literal(role)} WHERE {relation_filter} AND pg_catalog.has_table_privilege(r.oid,c.oid,{_literal(privilege)}))"
    condition = f"{granted}" if expected else f"NOT ({granted})"
    return f"(({role_exists}) AND ({condition})) IS TRUE"


_TYPE_ALIASES = {
    "bool": "boolean", "int2": "smallint", "int4": "integer", "int8": "bigint",
    "float4": "real", "float8": "double precision", "decimal": "numeric",
    "varchar": "character varying", "varbit": "bit varying",
}


def _function_lookup(signature: str) -> str:
    qualified_name, raw_types = signature[:-1].split("(", 1)
    schema, function_name = qualified_name.split(".")
    argument_types = [item.strip() for item in raw_types.split(",")] if raw_types.strip() else []
    expected = "ARRAY[" + ",".join(
        f"{_literal(_TYPE_ALIASES.get(item, item))}::text" for item in argument_types
    ) + "]::text[]"
    return f"""(SELECT p.oid FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname={_literal(schema)} AND p.proname={_literal(function_name)}
        AND ARRAY(SELECT pg_catalog.format_type(input_type.oid,NULL)
                 FROM unnest(p.proargtypes::oid[]) WITH ORDINALITY AS input_type(oid,ord)
                 ORDER BY input_type.ord) IS NOT DISTINCT FROM {expected})"""


def _function_check(spec: dict[str, Any]) -> list[tuple[str, str]]:
    signature = spec["signature"]
    fn = _function_lookup(signature)
    checks = [(f"function {signature} exists", f"{fn} IS NOT NULL")]
    checks.append((f"function {signature} ordinary function", f"EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.oid={fn} AND p.prokind='f')"))
    checks.append((f"function {signature} return type", f"EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.oid={fn} AND pg_catalog.format_type(p.prorettype,NULL)={_literal(spec['returns'])})"))
    checks.append((f"function {signature} set-returning mode", f"EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.oid={fn} AND p.proretset IS {'TRUE' if spec.get('returns_set', False) else 'FALSE'})"))
    checks.append((f"function {signature} security mode", f"EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.oid={fn} AND p.prosecdef IS {'TRUE' if spec['security']=='definer' else 'FALSE'})"))
    if "arguments" in spec:
        arguments = spec["arguments"]
        expected_names = [argument["name"] for argument in arguments]
        names_expr = "NULL::text[]" if not any(expected_names) else "ARRAY[" + ",".join("NULL::text" if name is None else f"{_literal(name)}::text" for name in expected_names) + "]::text[]"
        mode_codes = {"IN": "i", "OUT": "o", "INOUT": "b", "VARIADIC": "v", "TABLE": "t"}
        expected_modes = "ARRAY[" + ",".join(f"{_literal(mode_codes[argument['mode']])}::\"char\"" for argument in arguments) + "]::\"char\"[]"
        expected_types = "ARRAY[" + ",".join(
            f"{_literal(_TYPE_ALIASES.get(argument['type'], argument['type']))}::text"
            for argument in arguments
        ) + "]::text[]"
        checks.append((f"function {signature} argument names", f"EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.oid={fn} AND p.proargnames IS NOT DISTINCT FROM {names_expr})"))
        checks.append((f"function {signature} argument modes", f"EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.oid={fn} AND COALESCE(p.proargmodes, pg_catalog.array_fill('i'::\"char\", ARRAY[p.pronargs])) IS NOT DISTINCT FROM {expected_modes})"))
        checks.append((f"function {signature} argument types", f"EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.oid={fn} AND ARRAY(SELECT pg_catalog.format_type(argument_type.oid,NULL) FROM unnest(COALESCE(p.proallargtypes, p.proargtypes::oid[])) WITH ORDINALITY AS argument_type(oid,ord) ORDER BY argument_type.ord) IS NOT DISTINCT FROM {expected_types})"))
    else:
        # Without an argument declaration, only all-IN functions are verifiable.
        # Their names are intentionally not part of the consumer contract.
        checks.append((f"function {signature} has no output arguments", f"EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.oid={fn} AND p.proargmodes IS NULL)"))
    if "search_path" in spec:
        expected = "ARRAY['search_path=\"\"']::text[]" if spec["search_path"] == "" else f"ARRAY[{_literal('search_path=' + spec['search_path'])}]::text[]"
        checks.append((f"function {signature} search_path", f"EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.oid={fn} AND p.proconfig={expected})"))
    for role in spec["execute"]["allow"]:
        allowed = _function_execute_check(fn, role, expected=True)
        checks.append((f"function {signature} EXECUTE for {role}", allowed))
    for role in spec["execute"]["deny"]:
        denied = _function_execute_check(fn, role, expected=False)
        checks.append((f"function {signature} EXECUTE denied for {role}", denied))
    return checks


def _function_execute_check(function_oid: str, role: str, *, expected: bool) -> str:
    if role == "public":
        granted = f"EXISTS (SELECT 1 FROM pg_catalog.pg_proc p CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))) AS acl WHERE p.oid={function_oid} AND acl.grantee=0 AND acl.privilege_type='EXECUTE')"
        return f"({granted}) IS {'TRUE' if expected else 'FALSE'}"

    role_exists = f"EXISTS (SELECT 1 FROM pg_catalog.pg_roles r WHERE r.rolname={_literal(role)})"
    granted = f"EXISTS (SELECT 1 FROM pg_catalog.pg_roles r WHERE r.rolname={_literal(role)} AND pg_catalog.has_function_privilege(r.oid,{function_oid},'EXECUTE'))"
    condition = granted if expected else f"NOT ({granted})"
    return f"(({role_exists}) AND ({condition})) IS TRUE"


def build_checks(contract: dict[str, Any]) -> list[tuple[str, str]]:
    """Build named SQL boolean assertions using catalog metadata only."""
    checks: list[tuple[str, str]] = []
    caps = contract["capabilities"]
    for table in caps["tables"]:
        schema, name = table["schema"], table["name"]
        qualified = f"{schema}.{name}"
        checks.append((f"table {qualified} exists", f"EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname={_literal(schema)} AND c.relname={_literal(name)})"))
        relkinds = {"table": "r", "partitioned_table": "p", "view": "v", "materialized_view": "m"}
        relation_kind = table.get("relation_kind", "table")
        checks.append((f"relation {qualified} kind={relation_kind}", f"EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname={_literal(schema)} AND c.relname={_literal(name)} AND c.relkind={_literal(relkinds[relation_kind])})"))
        for col in table["columns"]:
            checks.append((f"column {qualified}.{col['name']} type/nullability", _column_check(schema, name, col)))
        for constraint in table.get("constraints", []):
            checks.append((f"constraint {qualified} {constraint['kind']}({','.join(constraint['columns'])})", _constraint_check(schema, name, constraint)))
        if "rls" in table:
            rls = table["rls"]
            checks.append((f"table {qualified} RLS enabled", f"EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname={_literal(schema)} AND c.relname={_literal(name)} AND c.relrowsecurity IS {'TRUE' if rls['enabled'] else 'FALSE'})"))
            if "forced" in rls:
                checks.append((f"table {qualified} FORCE RLS", f"EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname={_literal(schema)} AND c.relname={_literal(name)} AND c.relforcerowsecurity IS {'TRUE' if rls['forced'] else 'FALSE'})"))
            for policy_index, policy in enumerate(rls.get("policies", [])):
                checks.append((f"policy {qualified} metadata #{policy_index + 1}", _policy_check(schema, name, policy)))
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
        spec = {"kind": "foreign_key", "columns": fk["columns"], "references": {"table": f"{ref_schema}.{ref_table}", "columns": fk.get("referenced_columns", ["id"])}, "on_delete": fk.get("on_delete", "no_action"), "validated": fk.get("validated", True)}
        if "set_null_columns" in fk:
            spec["set_null_columns"] = fk["set_null_columns"]
        checks.append((f"Auth FK {fk['table']} -> {fk['references']}", _constraint_check(local_schema, local_table, spec)))
    for section in ("auth", "realtime"):
        dep = caps.get(section, {})
        for signature in dep.get("functions", []):
            checks.append((f"{section} function {signature} exists", f"{_function_lookup(signature)} IS NOT NULL"))
    for relation in caps.get("realtime", {}).get("relations", []):
        schema, name = relation["schema"], relation["name"]
        checks.append((f"Realtime relation {schema}.{name} exists", f"EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname={_literal(schema)} AND c.relname={_literal(name)})"))
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
