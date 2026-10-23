# Private Calendar MCP

A personal macOS Calendar integration with a Swift EventKit broker, a dependency-free Python MCP gateway and a stdio adapter for local clients or an official private Secure MCP Tunnel. It uses the calendars already configured in macOS, including iCloud; no iCloud password is collected.

Calendar changes use two steps: `preflight_change` returns the complete signed before/after preview, then `commit_create`, `commit_modify` or `commit_delete` receives that entire preview through the host's normal confirmation policy. The native broker checks identity and freshness and journals the exact payload before one mutation attempt. There is no Terminal approval prompt, approval endpoint or caller-controlled approval flag. Host policy is not proof of a fresh human click.

Requires macOS 14+, Swift 6 and Python 3.11+. Python runtime dependencies are standard library only. This is a private single-user integration, with no public ingress or public OAuth server. It covers all calendars exposed by macOS, including other configured accounts, subscribed calendars and read-only calendars.

```sh
cd "/absolute/path/to/iCloud Calendar MCP"
swift test
./scripts/build-helper.sh
python3 -m unittest discover -s Tests -v
```

Start with [Installation and operation](docs/setup.md), the authoritative clean-Mac checklist and runbook. Its separate current-deployment note records the Studio's active port and managed runtime; do not rebuild the settled authorized app merely to inspect it. Automated tests use synthetic fixtures and do not request Calendar permission. Build/test commands do not authorize real Calendar access. See [architecture](docs/architecture.md) for trust boundaries, audit semantics and validation limits.

An optional per-user login service stages with `calendar-mcp service render` and activates only with `service install`. Its independent monitor checks authenticated metadata, attempts bounded process recovery and local desktop alerts, and never replays Calendar writes. The user authorized installation on the Studio on 24 October 2026; separate controlled stops verified natural gateway and tunnel recovery. Startup is configured for GUI login following reboot; an actual reboot/login cycle and visible desktop alert delivery remain unverified. See the [service runbook](docs/setup.md#optional-login-startup-recovery-and-local-alerts).

On 24 October 2026 the Python suite ran 57 tests: 54 passed, including all 33 new service tests and native synthetic HTTP/stdio integration using the unchanged built helper; three explicit LaunchServices tests were skipped. Automated service tests use fake launchd/runtime operations; the real registration and recovery checks were separate metadata-only validation.

Earlier verification on this Mac passed the Swift build, 16 native tests and the then-current 24 Python tests, including explicit synthetic LaunchServices lifecycle/death/backpressure tests. The packaged app passed ad-hoc signature verification. Its actual resident LaunchServices broker reported full Calendar access through authenticated gateway status and exited after shutdown. The service change did not rebuild that bundle.

The nine tools cover calendar/event reads, availability, preflight, three separate commit operations and journal status. Queries are limited to 93 days. Initial writes support one event or occurrence and reject invitation/organizer mutations and entire-series changes. New events default to `Europe/London`; all-day end dates are exclusive. Availability is a snapshot, not a reservation.

On 23 October 2026 the user verified a real read, test create and delete through ChatGPT. Read-only journal/audit checks confirmed both writes `applied`, durable intent/completion, a valid five-record chain and no unresolved executions. The user confirmed the **create** prompt; the delete prompt and complete confirmation fields were not independently verified. Backend audit has no cryptographic proof of fresh human approval. Real modify and provider/recurrence/timezone edge cases remain unverified. No event details, personal times or opaque IDs are retained in this repository.
