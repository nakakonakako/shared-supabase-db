# shared-supabase-db

## Scope

- This repository owns the shared Supabase migration inventory, diagnostics, isolated SQL validation, and protected Dev/Prod Reader and Writer workflows.
- Do not modify receipt-manager or price-memo from this repository.
- Never run `db push` manually or use a local linked project for hosted DB access. Hosted checks and migration applies must use the existing workflows and only when the user explicitly authorizes that specific operation.
- Do not dispatch a Writer apply, enable either Writer flag, or perform a hosted DB write as part of ordinary development or documentation work. A production apply requires separate explicit approval.
- Hosted Reader checks and Writer identity probes are manually dispatched and use their dedicated Environments. PR CI must never receive Supabase credentials or connect to hosted projects.
- Never add project credentials, database URLs, service keys, or other secrets to tracked files.

## Migration safety

- Existing migration filenames and contents are immutable. Do not edit, delete, rename, or regenerate them.
- New migrations require an explicit task and must use the existing 14-digit timestamp naming convention.
- Update and verify `supabase/migrations/SHA256SUMS` only when an explicitly authorized new migration is added; never change an existing migration's recorded digest.
- Check the target environment's migration history with the documented Reader-only workflow before any migration apply. Do not infer Prod state from Dev or vice versa.

## Verification

- Run `npm run check` for changes in this repository.
- SQL suites must use dedicated disposable local PostgreSQL clusters/databases. The AI quota suite creates cluster-wide roles and requires a fresh cluster.
- Pull-request CI must not receive Supabase credentials or connect to hosted projects.
- Keep Reader checks, Writer identity probes, and Writer applies manual and main-only. Reader checks/probes must remain read-only; apply workflows must retain Environment approvals, identity checks, postflight, and explicit enablement gates.
- Do not assume an Environment or its credentials exist. Verify its protection and configuration through approved read-only means before use; never change GitHub Environment, Variable, or Secret settings unless separately authorized.

## Git

- Use a dedicated feature branch and create a pull request targeting the default branch.
- Do not merge, push to main/master, or deploy without explicit authorization.
- Commit only task-related changes. Use `<type>: <変更内容>` subjects.
