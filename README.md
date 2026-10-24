# Private Calendar MCP

A personal macOS Calendar integration with a Swift EventKit broker, a dependency-free Python MCP gateway and a stdio adapter for local clients or the official private Secure MCP Tunnel. It uses calendars already configured in macOS, including iCloud; no iCloud password is collected.

Deleting a calendar container is permanently prohibited, with no configuration or approval override. `commit_delete` deletes only one identified event or occurrence from its signed preview. Future-only scope, structural series changes and series deletion remain unsupported.

Calendar changes use a complete native-authenticated preflight followed by the matching commit tool under the host's normal confirmation policy. The broker refreshes identity and state, persists the exact immutable payload and nonce claim before mutation, and verifies the result. There is no Terminal approval prompt, remote approval API or caller-controlled approval flag. Host policy is not proof of a fresh human click. After an uncertain result, inspect `get_change_status` with the original nonce without retrying or preparing a replacement attempt.

The current security, series and alarm-order fix is deployed at `build/Calendar MCP Helper.app`. Its signed executable SHA-256 is `97d6a2fb537a769fda119cb50100597b99a1eac408f10acf34b2797c2f1baa01`; the tested frozen raw executable is `17898efb637eb7e13e31aac4b9358d0118c15405a04aaf69735a879795e8d37d`. The code-only alarm fix required no migration and preserved exact authoritative history, protected configuration and service budgets. The earlier approved upgrade established compatibility floor 3 with version-2 encrypted detail/marker encoding. Three executions remain: two applied and one unknown, with two quota claims and the valid two-record audit chain. No write was retried or reconciled.

All five security fixes are deployed: recursive Unicode/finite-number validation preserves healthy native channels after rejected input; stdio contains malformed IDs, initialization and result errors; optional recovery-window failure is isolated behind protected per-user IPC; native rejection/replay accounting and retention traversal are bounded/indexed; and project-owned clients authenticate protected Unix peers before emitting HTTP credentials or payloads. There is no project-client TCP fallback. Explicit external/manual loopback TCP clients retain their server-identity limitation and should use the protected project CLI/adapter or an independently authenticated encrypted channel.

During the earlier security/series rollout, the gateway and owned official adapter were cut over together, the managed tunnel was healthy, and the monitor restarted last. Protected Unix status/initialization and the exact fifteen-tool schema passed with zero Calendar tool calls. The old TCP listener received no bearer-credential probes. An initial read-only precheck stopped before changing services or state; the corrected reviewed rollout completed successfully. These observations establish deployment and local metadata behavior, not refreshed ChatGPT/iPhone discovery or live Calendar semantics.

The alarm fix makes complete raw alarm snapshots deterministic while preserving every value and duplicate; compatibility checks accept only order differences after validating original fingerprints. On the prior helper, an explicit OS grant restored resident full access and scoped read-only validation exposed this order-only mismatch in a version-4 preview. The replacement helper currently reports `eventkit` / `not_determined`, raw 0. Its explicit OS grant is pending; fixed-app read/preview validation remains pending. The tunnel is healthy, monitoring is current and rolling restart budgets remain 0/0. No actual Calendar write or recovery preflight ran. The existing unknown remains unresolved and blocks every fresh write. Provider propagation, recovery and host confirmation presentation remain unverified.

Recurring creation supports daily, weekly, monthly and yearly rules. Creation uses `scope:"series"` with typed `fields.recurrence`; occurrence edits/deletes use `scope:"this"`. Version-3 previews disclose that a deleted recurring occurrence can be recreated only as an independent standalone copy with new provider identity, leaving the series exclusion intact. Existing recurring deletes without that signed contract remain blocked. See [recurring events](docs/setup.md#individual-and-recurring-events).

Current-pattern default title, notes, plain location and alerts are also deployed through dedicated `commit_series_modify` and `commit_series_rollback` tools with exact version-4 previews. They target the provider's current recurring pattern from its first occurrence, including past and future occurrences within that pattern. Detached overrides/exclusions remain provider-controlled and earlier split segments are not merged. One operation may affect an unbounded number of occurrences and consumes one modify intent. One-source inverse recovery reapplies only retained prior defaults, subject to conservative later-intent guards. Verified recovery storage version 3 and the exact new capability expose fifteen tools; older helpers retain their supported schemas. Legacy occurrence commit tools reject version 4. See [the current-pattern runbook](docs/setup.md#current-recurring-pattern-default-fields).

Multiple display alerts can be supplied at creation or replaced through `fields.alerts`. Each of up to ten alerts uses `relative_minutes` or an absolute `at` timestamp with a UTC offset. Omission preserves existing alarms on modification; `[]` clears them. Adding, editing or removing an alert submits the complete desired list through the signed preview. See [event alerts](docs/setup.md#multiple-event-alerts).

Recovery retains detailed integration history for **five days by default**, configurable locally from 1 to 365 days. Ordinary multi-source recovery uses a complete paginated inventory and explicit batches of up to 25 changes; series inverse requires exactly one source selected alone. Expired details cannot be recovered, unresolved evidence remains protected, and recovery does not reproduce complete provider provenance or recurrence exception topology. The native window captures the displayed signed step before local Apply. See [retention and recovery](docs/setup.md#retained-history-and-recovery).

Native safety defaults are 50 deletes per rolling hour and 200 per rolling 24 hours, plus 100 combined modifies/deletes per rolling hour and 500 per rolling 24 hours. Durable intents count across calls, chats, calendars and restarts. Local operators may adjust the protected policy; quota is not consent and one series intent does not bound affected occurrences. If preflight has no `safety` feedback, cumulative protection is not confirmed. See [write-safety configuration](docs/setup.md#bulk-modify-and-delete-protection).

File attachments remain unsupported by the public EventKit backend. Metadata-only listing and a separate explicit content fetch are documented future requirements; the choice between a supported provider API and MCP-only associations remains pending. See [attachment findings and options](docs/attachments.md).

Final validation used synthetic providers, protected temporary state and local sockets:

- All 100 native tests passed in 38.177 seconds, including nine alarm regressions.
- The frozen helper passed 110 Python tests in 4.703 seconds: 107 passed and three explicit packaged LaunchServices tests were skipped.
- Those three lifecycle tests separately passed against the final staged signed app in 1.675 seconds with zero skips and an unchanged executable hash.

The actual synthetic version-4 modify/inverse/replay lifecycle and complete fifteen-tool protected Unix HTTP/stdio discovery ran successfully. Synthetic results do not establish provider propagation, first-anchor identity changes, detached overrides/exclusions, alert delivery, real recovery or host confirmation rendering.

Requires macOS 14+, Swift 6 and Python 3.11+. Python runtime dependencies are standard library only. This is a private single-user integration, with no public ingress or public OAuth server. Read-only/subscribed calendars can be queried but are not write targets.

```sh
cd "/absolute/path/to/iCloud Calendar MCP"
swift test
./scripts/build-helper.sh
python3 -m unittest discover -s Tests -v
```

Start with [Installation and operation](docs/setup.md) and [architecture](docs/architecture.md). Do not rebuild the installed app merely to inspect it. Build/test commands do not authorize real Calendar access. Optional per-user Aqua LaunchAgents supervise the gateway and bounded official tunnel recovery without submitting Calendar tools; an actual GUI login/reboot cycle and visible desktop notification delivery remain unverified.

Historical validation on 23 October 2026 used an earlier helper for a real read, test create and delete through ChatGPT. Both writes reached `applied`; the user confirmed the create prompt. The delete prompt and complete fields were not independently verified. Later alert/recurrence releases passed their synthetic suites and metadata-only rollouts. Those historical grants and results do not establish the final installed helper's current OS access or live series behavior; the later durable unknown remains authoritative.
