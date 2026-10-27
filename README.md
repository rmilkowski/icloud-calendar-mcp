# Private Calendar MCP

A personal macOS Calendar integration for ChatGPT and local MCP clients. It uses calendars already configured on the Mac, including iCloud, through EventKit. Connect locally or through the official private Secure MCP Tunnel; no iCloud password or model API key is required.

Remote access requires an always-on, internet-connected Mac, kept awake with the calendar owner logged in. The MCP server and tunnel run under that user's account. Once connected in ChatGPT or configured in a compatible Codex client, you can access that user's calendars from other devices, including your phone.

**Start here: [Quick install](docs/quick-install.md)** · [Full setup and operation](docs/setup.md) · [Architecture and safety contracts](docs/architecture.md)

## What it supports

- List calendars, query bounded event windows and inspect identified events.
- Create individual events or typed recurring series; modify/delete one identified event or occurrence.
- Set multiple display alerts and preserve omitted fields.
- Change current recurring-pattern defaults or strictly future defaults for title, notes, plain location and alerts through dedicated tools.
- Stop a supported recurring pattern from an explicit future cutoff, with separately confirmed, limited recovery as a new independent series.
- Create or correct supported nonrecurring floating all-day dates.
- Inspect retained change history, prepare supported inverse changes and explicitly assess an uncertain outcome through journal tools.

The full integration exposes 22 tools when the native helper supports their capabilities. See the [tool inventory](docs/architecture.md#mcp-tools) and [operation examples](docs/setup.md#individual-and-recurring-events).

## Requirements

Use macOS 14+, Swift 6/Xcode Command Line Tools and Python 3.11+ with timezone data. Python needs no extra packages. Remote ChatGPT access needs the official tunnel client, a private workspace/tunnel association and a restricted runtime credential. This is a single-user integration, without public ingress or multi-user authorization.

A fresh installation needs a signed helper app and local macOS Full Access. Preserve an existing installation's app, state and grant: rebuilding an ad-hoc signed app can reset permission.

## Consent, uncertainty and recovery

Every Calendar write uses an exact authenticated preview and its matching commit tool under the host's normal confirmation policy. The native broker checks the target and current state and records execution history. Normal writes have no Terminal approval step. Host policy is not proof of a fresh human click.

If a result is uncertain, inspect `get_change_status` with the original change ID; never blindly retry. Uncertain outcomes may block related writes. When the broker proves a change never started, a fresh reviewed attempt is allowed. See [execution and replay rules](docs/architecture.md#native-proof-of-non-execution-deployed) for the precise distinction.

Recovery is another reviewed write, with five-day default detail retention. It cannot promise to reconstruct the original recurring pattern. [Journal assessment](docs/setup.md#plugin-journal-assessment) records the user's explicit assessment without provider verification or a Calendar retry.

## Limits and security

Calendar-container deletion is permanently prohibited. Arbitrary structural series edits and historical/full-series deletion are unsupported. Detached overrides/exclusions remain provider-controlled; occurrence recovery makes a standalone copy, and cutoff recovery never merges a truncated pattern. For all-day events, fresh deletion, cutoff termination and copy restoration are unsupported. Attachments are [not implemented](docs/attachments.md).

Project clients use protected local transport. Recovery keys share SQLite with encrypted history; [state-storage limits](docs/setup.md#private-state-storage) explain why copies remain sensitive. Preserve authoritative history through upgrades; never downgrade or resume from older history after migration.

Synthetic tests do not prove every live provider or host behavior. Permission, service health, tool discovery and full confirmation rendering must be checked separately.

## Development checks

```sh
swift test
./scripts/build-helper.sh
python3 -m unittest discover -s Tests -v
```

Tests use synthetic providers and do not authorize Calendar access. Packaging replaces the local build bundle; use it only for a fresh or deliberately managed build. See [test and packaging options](docs/setup.md#2-build-sign-and-test-a-fresh-installation).
