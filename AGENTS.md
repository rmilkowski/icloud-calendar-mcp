# Project instructions

## Roles

- Implementation: GPT-6.1 Sol with high reasoning.
- Architecture decisions, architecture reviews and code reviews: Astra with high reasoning.
- Use these roles when explicitly delegating implementation, architecture or review work. Model overrides require a fresh-context agent (`fork_turns: "none"`); supply the task, current decisions and relevant files explicitly.

## Operational workflow

- Restarting services is approved when implementing fixes or new features.
- Database migrations without a database backup are approved for this change and future feature/fix changes. Preserve authoritative execution, audit, replay and quota history; after a migration commits, repair forward rather than downgrade or restore older state. Calendar access and write-consent requirements still apply.
- Commit each feature or fix separately.
- When present, consult `TODO.local.md` for deferred local follow-up and keep it uncommitted.

## Architecture maintenance

Read `docs/architecture.md` before system changes. Update it in the same change as architecture decisions, tool contracts, trust boundaries, confirmation behavior, audit design or implementation milestones. Keep diagrams and status accurate; distinguish planned, implemented and verified behavior.

ChatGPT native confirmation is the normal write-consent surface. Do not add Terminal approval prompts, a remote approval API or caller-controlled approval boolean. The native broker owns stateless authenticated previews, identity, stale checks, serialized execution, journal and audit. Commit persists the immutable execution payload and nonce claim before writing; preflight creates no pending approval workflow. Transport cannot choose replacement write payloads.

Deleting a calendar container is permanently prohibited through this integration, including future providers and local tooling. Do not add a calendar-removal operation or a configuration/approval override. Creation may target a new event or an explicitly specified recurring series. Modification/deletion normally targets one identified event or occurrence through the signed-preview flow. The user additionally authorized current recurring-pattern default-field modification for title, notes, plain location and alerts, with exact version-4 signed anchor/reference/field-mask previews and inverse-field recovery. This scope covers the provider's current pattern from its first occurrence, including past and future occurrences within that pattern; it does not merge earlier split segments or guarantee detached-override propagation. Future-only scope, structural series changes (dates, times, timezone, all-day, recurrence or calendar), and series deletion remain unsupported. Individually authorized event deletions and their configured quotas remain supported; recurring occurrence deletion must disclose standalone-copy recovery and its structural limitations in the signed preview.

## Calendar access and validation

Current-pattern version-4 writes use dedicated `commit_series_modify` and `commit_series_rollback` tools. Do not broaden legacy occurrence commit tools to accept this scope. Preserve the native storage-version-3 compatibility floor so older helpers cannot reinterpret series history; detailed payload/marker encoding and authoritative history remain preserved.

During the currently requested unattended follow-up, do not modify actual calendars. Complete source, synthetic validation and operational metadata work; leave the deferred local Calendar grant and any live write validation for the user to resume.

Use synthetic fixtures by default. Do not trigger macOS calendar authorization prompts or mutate real calendars during unattended tests. Respect existing, persisting user authorization: after OS access and scoped real integration validation are authorized, normal scoped reads do not need fresh confirmation. Real writes require an identified target and exact intended change through the selected host consent policy, enforced by native preview and journal checks. Build/test commands alone do not authorize calendar access.

Do not present host policy as proof of a fresh human click. Audit integration mutation attempts accurately, including unknown outcomes and replay. Never claim complete visibility into host denials or other calendar clients. Keep secrets out of logs and protect sensitive before/after data. Audit purge and backup restore must preserve replay protection and unresolved intent history.
