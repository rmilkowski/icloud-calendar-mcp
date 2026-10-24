# Project instructions

## Roles

- Implementation: GPT-6.1 Sol with high reasoning.
- Architecture decisions, architecture reviews and code reviews: Astra with high reasoning.
- Use these roles when explicitly delegating implementation, architecture or review work. Model overrides require a fresh-context agent (`fork_turns: "none"`); supply the task, current decisions and relevant files explicitly.

## Operational workflow

- Restarting services is approved when implementing fixes or new features.
- Commit each feature or fix separately.

## Architecture maintenance

Read `docs/architecture.md` before system changes. Update it in the same change as architecture decisions, tool contracts, trust boundaries, confirmation behavior, audit design or implementation milestones. Keep diagrams and status accurate; distinguish planned, implemented and verified behavior.

ChatGPT native confirmation is the normal write-consent surface. Do not add Terminal approval prompts, a remote approval API or caller-controlled approval boolean. The native broker owns stateless authenticated previews, identity, stale checks, serialized execution, journal and audit. Commit persists the immutable execution payload and nonce claim before writing; preflight creates no pending approval workflow. Transport cannot choose replacement write payloads.

## Calendar access and validation

Use synthetic fixtures by default. Do not trigger macOS calendar authorization prompts or mutate real calendars during unattended tests. Respect existing, persisting user authorization: after OS access and scoped real integration validation are authorized, normal scoped reads do not need fresh confirmation. Real writes require an identified target and exact intended change through the selected host consent policy, enforced by native preview and journal checks. Build/test commands alone do not authorize calendar access.

Do not present host policy as proof of a fresh human click. Audit integration mutation attempts accurately, including unknown outcomes and replay. Never claim complete visibility into host denials or other calendar clients. Keep secrets out of logs and protect sensitive before/after data. Audit purge and backup restore must preserve replay protection and unresolved intent history.
