# shared-supabase-db

## Scope

- This repository owns shared Supabase migrations, diagnostics, and isolated SQL validation.
- Do not modify receipt-manager or price-memo from this repository.
- Do not connect to a hosted Supabase project, run `db push`, or enable a writer workflow unless explicitly authorized in a later task.
- Never add project credentials, database URLs, service keys, or other secrets to tracked files.

## Migration safety

- Existing migration filenames and contents are immutable. Do not edit, delete, rename, or regenerate them.
- New migrations require an explicit task and must use the existing 14-digit timestamp naming convention.
- Update and verify `supabase/migrations/SHA256SUMS` only when an explicitly authorized new migration is added; never change an existing migration's recorded digest.
- Check Dev and Prod migration history independently using the documented read-only procedure before any future migration operation.

## Verification

- Run `npm run check` for changes in this repository.
- SQL suites must use dedicated disposable local PostgreSQL clusters/databases. The AI quota suite creates cluster-wide roles and requires a fresh cluster.
- CI must not receive Supabase credentials or connect to hosted projects.
- Keep workflows pull-request-only/read-only until a separate authorization changes this policy.

## Git

- Use a dedicated feature branch and create a pull request targeting the default branch.
- Do not merge, push to main/master, or deploy without explicit authorization.
- Commit only task-related changes. Use `<type>: <変更内容>` subjects.
