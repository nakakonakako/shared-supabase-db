"""Pinned Supabase target identifiers and their DBA-provisioned DB marker."""

EXPECTED_PROJECT_REFS = {
    "dev": "irgahixsuvtopiwmtkku",
    "production": "fsrbddgyysssqzyullrc",
}


def expected_database_identity(target: str) -> str | None:
    project_ref = EXPECTED_PROJECT_REFS.get(target)
    if project_ref is None:
        return None
    return f"shared-supabase-db:target={target};project_ref={project_ref}"
