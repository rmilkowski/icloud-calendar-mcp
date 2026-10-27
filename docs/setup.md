# Installation and operation

This is the detailed installation and operating reference. For a new Mac, start with [quick install](quick-install.md). For an existing installation, use the relevant maintenance section and preserve its state, configuration and settled app. **Do not rebuild an already authorized app just to follow this guide:** an ad-hoc signature change can reset its Calendar grant.

## Installation checklist

1. Configure the desired accounts in macOS Calendar, then install the prerequisites.
2. Build/sign the helper and run synthetic tests before requesting Calendar access.
3. Explicitly grant the bundled app full Calendar access on the Mac that will run it.
4. Initialize private state, start the local gateway and verify native authorization with `status`.
5. Download/verify the current official tunnel client, configure a private tunnel and restricted runtime credential, then start a managed runtime.
6. Add the tunnel in ChatGPT Plugins and verify a scoped read; separately verify each intended write path and its host confirmation.
7. Optionally stage and install the per-user login service and independent monitor after the manual setup works.

This integration reads **all calendars exposed by macOS**, including iCloud, other configured accounts, subscribed calendars and read-only calendars. It uses EventKit rather than collecting an iCloud password. Eligibility is checked per write target. It is a personal, single-user service; public ingress and public OAuth are not implemented.

File attachment listing, upload and content fetch are not implemented: the public EventKit API exposes no native file attachment operations. There is no attachment setup step or additional provider credential to configure. See [attachment findings and pending options](attachments.md) for the planned metadata-only listing and separate explicit content fetch; provider access and MCP-only storage remain unselected.

## 1. Prerequisites and source

Use macOS 14 or later, Swift 6/Xcode Command Line Tools, and Python 3.11 or later with IANA timezone data. Python runtime dependencies are standard library only; no `pip install`, Node.js or model API key is needed. The tunnel has its own runtime credential, separate from the gateway token.

Obtain the project source and work from its root. All command blocks below assume that working directory; paths with spaces are supported.

```sh
cd "/absolute/path/to/iCloud Calendar MCP"
swift --version
python3 --version
```

Before granting access, verify that the intended accounts/calendars are visible in the macOS Calendar app on this Mac.

## 2. Build, sign and test a fresh installation

```sh
./scripts/test-native
./scripts/build-helper.sh
python3 -m unittest discover -s Tests -v
```

The bundle is `build/Calendar MCP Helper.app`. The build script uses an ad-hoc signature by default and verifies it with `codesign --verify --strict`. For durable TCC identity across rebuilds, use an existing stable signing identity when first packaging:

```sh
CALENDAR_SIGNING_IDENTITY="Your existing code-signing identity" ./scripts/build-helper.sh
```

No signing identity or notarization is created by this project. Ad-hoc packaging works for local use, but a replacement/rebuild can require re-enabling Calendar access. Preserve the settled bundle after authorization instead of rebuilding it unnecessarily.

In managed Codex environments where nested SwiftPM `sandbox-exec` is unavailable, the verified fallback is:

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/calendar-mcp-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/calendar-mcp-swift-cache \
  ./scripts/test-native --scratch-path /private/tmp/calendar-mcp-native-build
env CLANG_MODULE_CACHE_PATH=/private/tmp/calendar-mcp-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/calendar-mcp-swift-cache \
  ./scripts/build-helper.sh
```

This disables SwiftPM's nested build sandbox, not the outer managed environment. The packaging script already selects this option. `swift build --show-bin-path` identifies the current toolchain's product directory; set `CALENDAR_MCP_TEST_HELPER` to that directory's `CalendarHelper` if test autodetection needs an override.

The native runner uses SwiftPM's parallel XCTest support with eight workers and full stress counts by default. Use `--workers 1` for serial comparison, `--workers 4` to compare lower concurrency, or `--mode routine` for a separate lower-volume development lane. Stress retains 500 initial plus 100 post-restart rejections and 400 replays each of two operations; routine uses 50 plus 10 and 40 each. Both lanes keep all mutation-family/master-witness scenarios, quota and selection boundary checks, migrations, crash/restart and integrity assertions. Setup-only transactions seed the 1,500 unrelated retention rows and 130 dependency nodes, and construct completed synthetic legacy/audit-corruption fixtures. Invariant retention-seed JSON and timestamp text are serialized once. Actual claims, outcomes, expiry, corruption checks and crash-resumption steps retain their original boundaries; every scenario still initializes fresh protected state.

The runner builds only into `.build/native-tests` by default and never packages or replaces the app. `--scratch-path` selects another build directory. For repeatable execution-only measurements, build once with the runner, then repeat `--skip-build` with the same path, mode, helper artifacts and worker count. Each run writes private build/test logs and a JSON summary, plus xUnit results for parallel runs with separate build/execution times and test/helper hashes; it reports skipped tests explicitly. Parallel xUnit case identities must match the source inventory; true serial runs instead require exact started/completed XCTest log identities and a consistent final All tests aggregate. Reports label their evidence format explicitly, and a source/test-binary/helper build manifest rejects stale `--skip-build` artifacts; partial reports cannot count as full-suite success. It forwards only selected toolchain and test-helper environment variables, excluding unrelated runtime credentials.

For a release compatibility run, set `CALENDAR_MCP_FROZEN_FLOOR6_HELPER` and `CALENDAR_LEGACY_HELPER` to the frozen executables and use `--strict-compatibility`. The current synthetic helper defaults to the chosen scratch build's `debug/CalendarHelper`; `CALENDAR_MCP_TEST_HELPER` can pin another build. Strict mode requires those executables plus the immutable older fixtures referenced by the existing tests and rejects any skipped tests. A fresh checkout without those private fixtures can run the normal developer lane, whose summary records the existing compatibility skips. Do not label a run with missing compatibility fixtures a complete release validation.

### Native test benchmarking

Compare three execution-only runs per configuration using the same debug build mode, full stress workload, frozen compatibility helpers and socket permissions, with no overlapping heavy jobs. Use `--skip-build` only after the runner has built and bound the current sources/artifacts. Report the median execution time separately from compilation; do not substitute routine-mode timings for full-stress results.

Measured debug execution times, excluding builds:

| Full-stress configuration | Samples | Execution time |
| --- | --- | --- |
| Original serial suite | 3 | 91.482 s median |
| Optimized true serial (`--workers 1`) | 1 | 84.777 s |
| Optimized parallel (`--workers 8`) | 3 | 25.635 s median |

The parallel median **reduces execution time by 71.98%** versus the original serial median. Baseline samples were 91.482/91.765/89.888 s; final eight-worker samples were 31.700/24.934/25.635 s. Both the baseline and serial control used SwiftPM's true `--no-parallel` execution. Its single sample indicates the nonparallel setup benefit without claiming a three-run median.

Focused serial fixture timings also improved: the 1,500-row retention case went from a three-run median of 4.310 s to 0.111 s in the final serial control; the 130-node dependency case went from 0.498 s to 0.181 s. Actual durable operations and assertions remain outside the setup batches.

Every final measured native run passed all 338 cases with zero failures/skips and exact inventory validation. The separate routine eight-worker sample was 23.928 s; it is not used for the full-stress performance claim. The Python suite passed 147 of 150 tests with its three existing packaged lifecycle skips; no new skips were added.

The scheduling refactor exposes 338 XCTest methods instead of 204 while preserving the same scenarios: 15 mutation pre-entry families, all 15 × 4 uncertain-outcome combinations, and 18 pre-intent/18 post-mutation/28 independent-copy excluded-master combinations. Full stress retains all 600 rejection and 800 replay calls plus the 1,500-row retention and 130-node dependency fixtures. The quota 50/51, recovery selection 25/26, concurrent quota, crash/restart and frozen-writer checks are unchanged.

Automated tests use synthetic providers and temporary state. Build/test commands do not authorize real Calendar access. HTTP tests need temporary protected Unix and private loopback listeners. Default tests skip explicit LaunchServices app-launch tests; after packaging, opt into those synthetic-only lifecycle tests with:

```sh
CALENDAR_MCP_TEST_LAUNCH_SERVICES=1 python3 -m unittest discover -s Tests -v
```

An optional synthetic gateway check, still without TCC or real Calendar data:

```sh
./scripts/calendar-mcp init --state-dir "$PWD/.state/synthetic"
./scripts/calendar-mcp serve --state-dir "$PWD/.state/synthetic" \
  --helper "$PWD/build/Calendar MCP Helper.app/Contents/MacOS/CalendarHelper" \
  --backend synthetic --port 8765
```

In another Terminal run `./scripts/calendar-mcp status --state-dir "$PWD/.state/synthetic" --port 8765`; expect `not_applicable`. Stop that synthetic gateway with Ctrl-C before reusing its port. Synthetic event fixtures reset on process restart, while their journal/identities persist; this does not simulate EventKit persistence.

## 3. Grant Calendar permission to the app

This is an explicit local user step, separate from consent to any event change. Skip it if the settled app already has full access. Launch the exact app through LaunchServices:

```sh
(
  umask 077
  calendar_authorization_output=$(mktemp -d /private/tmp/calendar-authorize.XXXXXX)
  /usr/bin/open -n -W -g \
    --stdout "$calendar_authorization_output/result.json" --stderr /dev/null \
    "$PWD/build/Calendar MCP Helper.app" --args --authorize
  cat "$calendar_authorization_output/result.json"
  rm -f "$calendar_authorization_output/result.json"
  rmdir "$calendar_authorization_output"
)
```

Accept the macOS prompt on the **execution Mac's logged-in desktop**. If controlling a Studio from a laptop, use the Studio's desktop/Screen Sharing; changing laptop Calendar settings does not grant Studio access. In System Settings → Privacy & Security → Calendars, enable full access for Calendar MCP Helper as needed.

If authorization is denied or a signature replacement reset it, inspect the local bounded diagnostics and enable the settled app in Settings; toggling that app off/on may be necessary after a signature change. Do not reset TCC or edit its database. Existing grants persist and do not need repeated requests.

Direct `.app/Contents/MacOS/CalendarHelper --status` or `--authorize` can inherit Python/Terminal responsibility attribution and report a different permission result. Production EventKit mode therefore always launches the exact matching `.app` through LaunchServices. Use the running gateway's `status` below to verify the actual broker; do not grant unrelated host processes Calendar access as a workaround.

## 4. Start the gateway and check status

Choose one HTTP authority port and use it consistently for gateway, adapter and tunnel. The default is 8765. If it is occupied, choose another port; do not stop an unrelated listener. Source project clients use this port to derive a protected Unix endpoint, rather than connecting over TCP.

```sh
./scripts/calendar-mcp init
./scripts/calendar-mcp serve \
  --helper "$PWD/build/Calendar MCP Helper.app/Contents/MacOS/CalendarHelper" \
  --backend eventkit --port 8765
```

Keep that foreground command running. The default private state is `$HOME/Library/Application Support/Private Calendar MCP`; its directory is `0700`, gateway token is `0600`, and native state lives in `native-eventkit`. A different `--state-dir` must also be supplied to the adapter/status client. Initialization never displays the token.

In another Terminal, from the repository:

```sh
./scripts/calendar-mcp status --port 8765
```

Expect `gateway: reachable`, native `backend_mode: eventkit`, `authorization_status: full_access`, raw 3. Status queries only authorization metadata from the actual resident broker: no EventKit store, calendar/event query or permission prompt. A reachable gateway can report denied/not-determined, so inspect the native state rather than treating reachability as a grant.

An already running helper can retain its earlier permission observation after the exact app receives an OS grant. If a fresh LaunchServices status process for that app reports full access while the resident broker still reports raw 0, coordinate a restart with the same settled bundle, state and port. For the installed service, hold the lifecycle lock, pause the monitor, boot out the owned gateway and wait for bounded teardown/native state-lock release, then bootstrap the same gateway. Verify actual resident `full_access` / raw 3, protected HTTP/stdio metadata and owned tunnel health; restart the monitor last and confirm a current check after releasing the lifecycle lock. Preserve service budgets and authoritative journal state. A healthy owned tunnel/adapter can remain running for this permission refresh; refresh it when a code/configuration rollout requires it. A separate helper's grant is not proof that the resident broker is ready.

The deployed gateway has a protected Darwin Unix listener alongside literal `127.0.0.1` HTTP. The stdio adapter, status/history CLI and service monitor use only Unix HTTP. They validate the private OS temporary base, owned `0700` parent and owned `0600` single-link socket, then verify the connected peer UID with libc `getpeereid` before sending HTTP bytes. The listener checks peer UID before parsing HTTP. The authority/Host remains `127.0.0.1:<port>`. There is no TCP fallback, proxy routing, redirect or request retry. Same-UID malicious processes remain outside file-permission isolation.

The source requires Darwin peer identity support and private per-user temporary storage, independent of `TMPDIR`. The short endpoint is derived from canonical gateway state and actual authority port; missing or unsafe transport fails closed. See [transport architecture](architecture.md#trust-boundaries) for exact derivation, validation and lifecycle rules. MCP uses authenticated POST `/mcp`; GET `/mcp` is 405 and there is no SSE subscription. Authenticated GET `/status` is local diagnostics, not an extra MCP tool. The adapter reads the protected token itself; do not put it in client configuration.

Manual third-party TCP HTTP retains its existing server-identity limitation: another UID can prebind the port while the gateway is down and capture a bearer sent to it. Use the protected project client or an independently authenticated encrypted channel. The direct manual TCP interface does not receive Unix peer authentication; do not send a bearer to an old or unidentified TCP listener to test whether it is the gateway.

EventKit IPC uses owned `0700` temporary directories and `0600` request/response/lifetime FIFOs. Only the gateway holds the noninherited lifetime writer. An independent native watchdog stops a broker even if execution/output blocks when the gateway dies. Native PID is diagnostic metadata and is never a signalling authority. No private TCC API or raw-executable production fallback is used.

For a manual restart, stop the existing gateway gracefully, rerun the same `serve` command with the same state/port/bundle, then check status. The optional service below makes login startup and bounded recovery an explicit installation choice; avoid duplicate gateways for one native state.

## 5. Install the official private tunnel client

Use the current [official Secure MCP Tunnel guide](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels) and its [latest release](https://github.com/openai/tunnel-client/releases/latest). Do not assume the version recorded in this repository is still latest.

1. Check `uname -m` and select the release's matching macOS architecture asset (`darwin-arm64` for Apple Silicon; select the release's published Intel asset for an Intel Mac).
2. Download its archive and published `SHA256SUMS` into an ignored `build/tools/tunnel-client/<release>/` directory. Check the exact archive filename/hash against the checksum file and GitHub's release-asset SHA-256 digest before extracting.
3. Keep the extracted client and accompanying bundled resources together. Check `file /path/to/tunnel-client`, `codesign --verify --strict /path/to/tunnel-client`, `/path/to/tunnel-client --version` and `/path/to/tunnel-client help quickstart`.

`shasum -a 256 /path/to/downloaded.zip` calculates the archive hash for comparison. Do not treat a successful download or a checksum from an unrelated filename as verification. No global PATH installation is required. The examples below use the v0.0.17 CLI layout under `build/tools/tunnel-client/v0.0.17/`; substitute the newly verified path below on a fresh install.

## 6. Configure credentials and a managed private tunnel

In [Platform tunnel settings](https://platform.openai.com/settings/organization/tunnels), select/create the intended private tunnel and associate the intended Platform organization and ChatGPT workspace. Tunnel creators need Read + Manage; the runtime credential/operator needs Read + Use. Workspace permission to add/use a custom MCP server is separate. Use the existing tunnel ID when reusing an installation; opaque IDs belong in private local configuration, not this repository.

Create/reuse a restricted **runtime** credential through the trusted local credential workflow. This is separate from the gateway token and from a model API key; no model API calls are made. Never give a long-lived runtime an admin key. Save the runtime credential as a `CONTROL_PLANE_API_KEY` environment assignment in user-approved `.state/tunnel.env` using a trusted secret writer/local editor, not a literal in shell commands or chat. Prepare the private destination before saving:

```sh
(
  umask 077
  mkdir -p .state
  chmod 700 .state
  touch .state/tunnel.env
  chmod 600 .state/tunnel.env
)
```

Do not overwrite an existing credential unnecessarily. The file is ignored by Git. The initial manual connection below sources **only this trusted, user-approved file**, with tracing disabled; never `cat` it or print the environment. For compatibility with the optional service's strict loader, keep it to one literal `CONTROL_PLANE_API_KEY=...` assignment; comments and an optional `export` are supported, but shell commands, substitutions and other variables are not. The service never sources or evaluates it. The managed profile stores `env:CONTROL_PLANE_API_KEY`, not a plaintext key.

From the repository, set the actual verified client path and chosen gateway port, then connect the existing private tunnel with supported supervision:

```sh
calendar_tunnel_client="$PWD/build/tools/tunnel-client/v0.0.17/tunnel-client"
calendar_port=8765
calendar_mcp_command=$(python3 -c 'import pathlib,shlex,sys; print(shlex.join([str(pathlib.Path.cwd()/"scripts/calendar-mcp"),"stdio","--port",sys.argv[1]]))' "$calendar_port")
(
  set +x
  set -e
  unset CONTROL_PLANE_API_KEY
  set -a
  . "$PWD/.state/tunnel.env"
  set +a
  : "${CONTROL_PLANE_API_KEY:?approved local runtime credential missing}"
  "$calendar_tunnel_client" runtimes connect \
    --alias calendar --profile calendar --profile-dir "$PWD/.state/tunnel-profiles" \
    --runtime-api-key env:CONTROL_PLANE_API_KEY \
    --tunnel-id YOUR_PRIVATE_TUNNEL_ID \
    --mcp-command "$calendar_mcp_command"
)
"$calendar_tunnel_client" runtimes status calendar --json
```

Replace the placeholder ID locally, without committing it. `runtimes connect` attaches the existing tunnel without admin CRUD, creates/reuses the local profile and supervises the runtime. Do not use `nohup` or `disown` for this client. Report it connected only when status shows running, healthy and ready. These flags were checked against installed v0.0.17 help; recheck help if a newer client changes them.

The admin UI is loopback-only on the client host, with a dynamic URL recorded at `$HOME/Library/Application Support/tunnel-client/health/<alias>.url`. It may require Screen Sharing or an explicit user-configured SSH port forward to view from another computer; `127.0.0.1` on the laptop is not the Studio. Keep the client running for discovery and tool calls. A healthy polling connection is not proof of a successful MCP read or write.

## 7. Add the private tunnel in ChatGPT

In [ChatGPT Plugins](https://chatgpt.com/plugins), choose plus → **Add custom MCP server** → **Connection: Tunnel**, then select the same tunnel. For this adapter design choose **No authentication** in that form: workspace/tunnel access is the private outer boundary, and the local adapter authenticates separately to the loopback gateway. This follows the [official private-tunnel example](https://developers.openai.com/cookbook/examples/partners/aws/chatgpt_agents_sdk_aws_agentcore_cookbook/notebooks/chatgpt_agents_sdk_aws_agentcore_cookbook#7-test-the-plugin-connection-in-chatgpt-through-secure-mcp-tunnel). Do not assume an arbitrary static bearer-token form exists or paste the local gateway token there.

This is appropriate only for the intended trusted personal workspace/tunnel association. It does not provide per-user backend identity or multi-user authorization. Review the warning and create the plugin. If the tunnel is missing, check organization/workspace association and Read + Use access. No public listener, router forwarding or public OAuth implementation is included.

After server tool, schema or instruction changes, refresh and verify the private custom plugin before testing the changed capability:

1. Check that the active ChatGPT workspace and selected plugin use the intended server/tunnel association.
2. On the web, open the plugin's management/details page in app settings and scroll to the bottom: the user found **Refresh tool** there. Use it to pull current tools, descriptions and server instructions, and enable the intended tool toggles. This observed path is the web page; mobile app menus remain unverified. See the [custom MCP management workflow](https://developers.openai.com/api/docs/guides/custom-mcp-server#how-to-use).
3. Verify all 22 tools, including `list_unresolved_changes`, `preflight_reconciliation` and `commit_reconciliation`, and `preflight_change.scope` accepting `this`, `series` and `future`. Confirm dedicated `commit_series_modify` / `commit_series_rollback`, `commit_future_modify` / `commit_future_rollback` and `commit_future_delete` / `commit_future_restore`. Legacy `commit_modify` and `commit_delete` intentionally remain occurrence-only. Future deletion additionally requires an exact cutoff; its recovery creates a separate new series with the signed limitations below. User-directed structural series edits and arbitrary historical/full-series deletion remain unsupported.
4. In a fresh chat, use `@` to select the correct plugin and explicitly request only `preflight_change` with `action: modify`, `scope: series`, an identified event and the exact intended default-field patch. Inspect expanded JSON tool details. This diagnostic prepares a preview only; do not call a commit tool.

If the plugin also has publishing controls, use **MCPs** → connected server → **Issues** → **Rescan**, wait for completion, then inspect **Issues found**, **Held update** and **Live definition**. New tools require approval; held changes leave existing tools' previously approved metadata live. See the [published-plugin update workflow](https://developers.openai.com/plugins/deploy/submission#update-to-your-mcp-server). These controls have not been verified in the user's private-plugin UI.

Verify tool discovery and a scoped read first. For a user-authorized disposable write test, review the complete signed preflight and host confirmation, then check the resulting event and journal outcome. Create/modify/delete have separate tools and permission scopes; success of one does not verify the others or guarantee a new prompt on every call.

## Optional login startup, recovery and local alerts

Install this only after the manual gateway and managed tunnel work. It adds two per-user Aqua LaunchAgents: a foreground gateway at GUI login, and an independent monitor at login and every 60 seconds. After reboot, the owning user must unlock FileVault if enabled and log into the Mac's GUI. This is not a pre-login daemon. Keep the settled helper bundle and its existing Calendar grant; registration does not rebuild it.

First stage private configuration and plists without changing the running services. Use absolute paths and the existing private tunnel ID locally. For the fresh-install examples above:

```sh
./scripts/calendar-mcp service render \
  --helper "$PWD/build/Calendar MCP Helper.app/Contents/MacOS/CalendarHelper" \
  --tunnel-client "$PWD/build/tools/tunnel-client/v0.0.17/tunnel-client" \
  --tunnel-id YOUR_PRIVATE_TUNNEL_ID \
  --tunnel-env "$PWD/.state/tunnel.env" \
  --profile-dir "$PWD/.state/tunnel-profiles" \
  --alias calendar --profile calendar --port 8765
./scripts/calendar-mcp service status
```

`render` writes protected `config.json` and `local.calendar-mcp.gateway.plist` / `local.calendar-mcp.monitor.plist` under the selected state directory's `service` directory (`0700`, files `0600`). It does **not** install or start jobs. The default state is `$HOME/Library/Application Support/Private Calendar MCP`; pass the same explicit `--state-dir` to every service command if using another location. `--python` can select an absolute Python interpreter; `--no-notify` disables desktop notification attempts. The credential remains in the approved env file and is passed through the runtime process environment, never stored in a plist, profile, command argument or log.

To activate, first stop the existing manual managed runtime with `runtimes stop <alias>` and gracefully stop the manual gateway. The installer refuses an occupied port, an existing managed runtime or conflicting launchd jobs; it does not take them over or kill their PIDs. Then explicitly install:

```sh
./scripts/calendar-mcp service install
./scripts/calendar-mcp service status
```

Installation registers the jobs in the owning user's GUI launchd domain and starts them. The monitor uses the official client's managed `runtimes status`, `stop` and `connect` operations; it does not launch a second tunnel daemon. After the startup grace, check authenticated gateway/native metadata and the tunnel's separate process-running, healthy and ready state. A healthy tunnel does not verify tool discovery, reads or writes. The monitor does not query Calendar data or request permissions.

`service status` distinguishes staged configuration from installed registration. Its `active` field requires both launchd jobs to be registered; inspect `gateway_registered`, `monitor_registered`, gateway/tunnel health and `last_check` separately. `monitor_stale: true` means no check is recorded within 180 seconds. `restart_attempts_last_hour` reports the persisted per-component rolling budget; registration alone does not prove health.

Recovery waits for a 120-second startup grace and three consecutive failed checks. It uses durable per-component backoff (nominally 60/120/240 seconds, capped at 15 minutes), with at least 120 seconds of grace after each restart; the first three effective delays are 120/120/240 seconds. A component gets at most three restart attempts per hour. Busy native work interrupts the failure streak and is never restarted by the monitor. Repeated five-second gateway HTTP timeouts can trigger owned-gateway recovery after the failure/grace thresholds. Denied/not-determined Calendar permission alerts for local repair; ambiguous status or ownership conflicts require operator inspection, and a gateway dependency failure does not trigger a tunnel restart loop. A restart restores process availability and never replays a submitted Calendar mutation. For an uncertain write, retain its original nonce and follow the journal recovery steps below.

A new boot/login session refreshes startup observations without clearing the rolling restart budget, backoff or existing incidents. The expected initial tunnel connection is logged as startup and consumes a bounded attempt without an outage alert; a failed startup alerts after grace.

By default the monitor attempts deduplicated outage and recovery desktop notifications and records bounded private operational events in `service/monitor.log` (with one rotated `.1` file). Recovery is reported only after 120 seconds of sustained healthy checks. `service/monitor-state.json` persists recovery limits; missing, corrupt or incompatible state suspends recovery and records `service/monitor-error.json` with one notification attempt. Do not delete this state to reset a restart budget. `gateway-launch.log` and `monitor-launch.log` hold private launch diagnostics. These are operational logs, separate from the native execution audit. Notification delivery depends on macOS permissions, Focus and the logged-in GUI session. Local alerts cannot report a powered-off/offline Mac to another device; no email, push service or other external delivery is configured.

To disable startup and recovery, uninstall the jobs:

```sh
./scripts/calendar-mcp service uninstall
./scripts/calendar-mcp service status
```

Uninstall stops the monitor before the service-owned tunnel and gateway and removes registration. It preserves credentials, tunnel profiles, the helper bundle and native journal/audit state. Uninstalling a staged-only configuration must not stop a preexisting manual gateway or runtime. Use the manual commands again if returning to foreground operation; reinstall explicitly to enable login startup again.

Synthetic service validation can run without registration, Calendar access or tunnel connections:

```sh
python3 -m unittest discover -s Tests -p 'test_service.py' -v
```

## Optional local Codex connection

This connects clients running on the **same Mac** as the gateway, using stdio without copying tokens:

```toml
[mcp_servers.calendar]
command = "/absolute/path/to/iCloud Calendar MCP/scripts/calendar-mcp"
args = ["stdio", "--port", "8765"]
default_tools_approval_mode = "writes"
tool_timeout_sec = 55
```

For synthetic tests add its explicit `--state-dir` to `args`. The documented `writes` policy prompts for tools not marked read-only; remembered/per-tool settings can affect it. See [Codex MCP configuration](https://developers.openai.com/codex/mcp). Registering a command alone does not establish its approval policy. A remote laptop does not automatically use this Mac's local configuration; an SSH stdio launch or other remote arrangement must be explicitly configured and authorized separately.

## Bulk modify and delete protection

The native helper enforces cumulative protections for destructive changes with a durable intent ledger. Real-provider quota enforcement is not comprehensively verified. For compatibility with older helpers, tool wording remains conditional: if preflight has no `safety` feedback, cumulative protection is not confirmed. Source edits or policy files cannot upgrade an older binary. Preserve the settled app and verify its actual resident authorization; do not rebuild it merely for status checks.

Default allowances are **50 deletes per rolling hour and 200 per rolling 24 hours**, with an additional **100 combined modifies/deletes per rolling hour and 500 per rolling 24 hours**. A delete counts in both categories. Creates do not consume these destructive allowances. There is no smaller burst cap: dozens of changes can run promptly if sufficient allowance remains.

Every fresh durable modify/delete intent counts, even repeated edits of the same event, across chats, calls, calendars, credentials and restarts. Preflight and rejected attempts before durable intent do not count; replay of an existing nonce does not count again. Unknown outcomes and later `not_applied` reconciliation retain their charge. Preflight returns advisory `safety` feedback beside the signed `preview`, with per-limit usage/remaining allowance and retry-time information; commit accepts only the preview and checks the current allowance atomically with recording its exact immutable intent before EventKit. Another call or a local policy change can therefore invalidate the earlier allowance estimate. Check the original nonce's status after a lost response; do not generate replacement previews to retry an uncertain write.

A trusted local operator can edit the fixed policy at:

```text
$HOME/Library/Application Support/Private Calendar MCP/native-eventkit/write-safety.json
```

For a custom gateway state directory use its `native-eventkit/write-safety.json`; synthetic state uses `native-synthetic/write-safety.json`. The path is fixed by the native state directory and cannot be supplied through an MCP call. The sanitized [policy example](write-safety.example.json) contains the defaults:

```json
{
  "version": 1,
  "delete_hour": 50,
  "delete_day": 200,
  "destructive_hour": 100,
  "destructive_day": 500
}
```

Use a trusted local editor to save the complete JSON as a user-owned regular file with **mode `0600`** inside the protected **`0700`** native directory. Preserve an existing policy rather than blindly copying the example over it. Symlinks, multiple hard links, files larger than 16 KiB, unknown/duplicate fields, noninteger limits and partial JSON are rejected. Each limit must be 1–100000; each day value must be at least its hour value, and each `destructive` value at least the corresponding `delete` value. There is no disable/unlimited setting. Atomic replacement by a protected regular file avoids exposing partially saved JSON; an invalid intermediate save fails closed.

The broker reloads the file during destructive preflight/commit, so a valid policy update needs no service restart. Preflight is advisory and does not adopt the file. A destructive commit durably adopts accepted policy revisions and audits their old/new values, hash and revision as local configuration, including if that commit is then rejected for insufficient quota. Initially, absence uses defaults; once a commit adopts an explicit file, removing it fails closed for new destructive calls rather than restoring defaults. Restore a complete valid protected file to repair that condition. Missing/invalid file errors use `write_safety_configuration`; exhausted limits use `write_safety_limit` with a safe retry time. These policy errors leave reads, status, creates and authenticated replays available; the scoped unresolved-intent guard independently blocks conflicting or insufficiently evidenced writes, with conservative calendar/global fallbacks for legacy history. Native database corruption/migration errors can still prevent startup. Raising or lowering limits never resets the durable usage ledger, even if the file is changed back. Native startup backfills existing durable modify/delete intents during upgrade. Restarting, credential rotation and reconciliation also preserve counts and the effective-time watermark used to clamp backward clock movement.

For a larger intended job, identify the exact changes, inspect the `safety` usage returned by a relevant `preflight_change`, and choose explicit local limits sufficient for the job plus existing rolling usage. Edit only the needed local values. Each write still uses a complete preview and the host's normal confirmation policy; quota is not consent. Return to the preferred limits afterward; charges remain until their windows expire. If limits are lowered below recent usage, further charged writes remain blocked until usage ages out or the operator sets sufficient limits. No remote caller can raise these values.

These safeguards bound volume and rate, not intent. A harmful request below the caps can still fit within them, particularly for a small calendar. They do not cover changes made through other apps, prove a fresh human click, or resist a same-user attacker rewriting protected state. Advancing the trusted system clock can age the rolling windows. Preserve complete state/history across maintenance and backups as described below.

## Individual and recurring events

Individual and recurring events use the existing preflight and commit tools, with typed series creation and signed standalone-copy recovery for a deleted recurring occurrence. Real Calendar recurrence behavior and host presentation are not comprehensively verified. Do not run the following examples against live calendars during unattended validation.

Create an individual event with `action:"create"`, `scope:"this"`, an exact writable `calendar_id`, and title/start/end fields. Create a recurring series by calling `preflight_change` with the following arguments, substituting the calendar ID returned by `list_calendars`:

```json
{"action":"create","scope":"series","calendar_id":"<opaque-calendar-id>","fields":{"title":"Weekly planning","start":"2026-11-02T10:00:00Z","end":"2026-11-02T10:30:00Z","time_zone":"Europe/London","recurrence":{"frequency":"weekly","interval":1,"days_of_week":[2,4],"end":{"count":12}},"alerts":[{"relative_minutes":-15}]}}
```

Pass the complete returned `preview` unchanged as `commit_create`'s `preview` argument through the normal host consent policy. The signed version-3 envelope includes `scope:"series"`, the canonical recurrence rule, complete fields/alerts and `recovery:{"mode":"not_applicable","limitations":[]}`. Creating a series does not grant permission to change or delete its occurrences later.

`frequency` is `daily`, `weekly`, `monthly` or `yearly`. `interval` defaults to 1 and accepts integers from 1 to 999. Omitted or null `end` means unbounded recurrence; use exactly `{"count":1}` through `{"count":1000}`, or `{"until":"2027-11-02T10:00:00Z"}` with an explicit offset and an instant at or after start. `days_of_week` is optional and weekly-only, with unique integers from 1 (Sunday) through 7 (Saturday); the start weekday in the event's named timezone must be included. Weekly intervals use Monday week boundaries; monthly/yearly rules skip dates absent from a month/year rather than clamping the anchor date. The native broker validates the named timezone, offset and rule and sorts explicit weekdays in its canonical preview. Recurrence null, empty/duplicate weekdays, unsupported rule keys and recurrence on `scope:"this"` are rejected.

Use a bounded `query_events` window and `get_event` to identify the exact occurrence; its opaque `event_id` binds the occurrence, including after a start-time edit. An occurrence modification uses:

```json
{"action":"modify","scope":"this","event_id":"<opaque-occurrence-id>","fields":{"title":"Planning moved this week","start":"2026-11-04T11:00:00Z","end":"2026-11-04T11:30:00Z"}}
```

Commit the returned complete preview through `commit_modify`. Omitted fields and existing recurrence remain preserved; a moved occurrence may become detached under provider semantics. Modification recovery restores displayed fields while preserving the current occurrence and series structure. It cannot undo historical detachment or restore former series inheritance; this is signed in both the ordinary preview and the recovery preview.

Delete only the identified occurrence with:

```json
{"action":"delete","scope":"this","event_id":"<opaque-occurrence-id>"}
```

The returned version-3 `recovery.mode` is `standalone_copy`. Its signed limitations include this exact disclosure:

> Recovery recreates only this occurrence as a standalone event with new provider identity. It does not remove the series exclusion, reattach the occurrence, restore series membership, or make future series edits apply to the copy.

Commit the complete preview through `commit_delete`. To recover that retained deletion, inspect its history, call `preflight_rollback` with `{"change_ids":["<returned-change-id>"]}`, and commit the exact returned step preview through `commit_rollback`. The recovery envelope remains version 2 and signs this same limitation alongside exact retained fields and raw alarms. The recreated copy is independent; the original series continues to exclude the occurrence. Recovery uses current stale/eligibility/journal checks and does not claim to restore native attachment inventory. Legacy recurring deletes lacking the exact signed disclosure remain blocked for both fresh execution and automatic recovery.

The installed combined helper accepts restricted future default-field modification and cutoff termination through the dedicated version-5/version-6 contracts below. User-directed structural series edits, arbitrary historical/full-series deletion, changing an existing recurrence rule and calendar container deletion remain unsupported; the separate version-6 contract below provides cutoff termination with limited independent-copy recovery. Current-pattern default-field modification is supported through the separate version-4 contract below. EventKit does not expose complete exception/exclusion topology needed to snapshot, authenticate, verify and recover those structural operations safely. This includes avoiding claims that a bounded query reveals every exception or that a standalone copy repairs series structure. A future structural feature needs a separate reviewed provider contract and recovery design.

The gateway independently probes exact metadata-only `recurrence_capabilities({})`. Recurrence publication and version-3 ordinary commits additionally require exact alert capability support; recovery tools still require their separate existing recovery capability. Unknown operations, failed or malformed probes retain the exact version-1/version-2 schemas supported by that helper and reject recurrence/version-3 requests before native dispatch. Updating Python alone cannot enable the feature. Version-1/version-2 authenticated previews, encrypted execution history, nonce consumption, quotas and unresolved outcomes remain preserved; no storage migration is needed.

## Current recurring-pattern default fields

This feature is synthetically validated and deployed. It allows current-pattern title, notes, plain location and alerts through two dedicated write tools, with an exact minimum-floor-3 capability retained in the current floor-7/22-tool deployment. Its version-4 contract does not enable structural series edits, future-only scope, series deletion or calendar-container deletion; future default fields have a separate version-5 contract below. Recurrence and ordinary occurrence contracts remain unchanged. Do not run these examples against actual calendars during unattended tests.

Version-4 series discovery requires its exact minimum-floor-3 capability and a recognized actual floor >=3. The current writer is floor 7 with encoding 2. Preserve authoritative execution, replay, audit and quota history during upgrades; repair forward after migration rather than downgrading or restoring older state.

Identify the intended non-detached occurrence through normal scoped reads. Request the exact default-field change with `preflight_change`, for example:

```json
{"action":"modify","scope":"series","event_id":"<opaque-selected-occurrence-id>","fields":{"title":"Updated planning title","notes":"Updated default description","location":"Meeting room","alerts":[{"relative_minutes":-15}]}}
```

Only the supplied fields change. Omitted alerts preserve complete native alarms; `alerts:[]` clears them. Dates/times, timezone, all-day state, recurrence rules and calendar moves are rejected. Changing a structured location remains unsupported. The complete version-4 preview shows the originally selected occurrence, the first-anchor before/after fields, sorted `series.changed_fields` and signed limitations. Submit that unchanged `preview` through `commit_series_modify` under the host's confirmation policy. The ordinary `commit_modify` does not accept this broader preview.

The provider applies these defaults from the first occurrence of its current recurring pattern, including past and future occurrences within that pattern. Separate split segments are not merged. Detached overrides and exclusions remain provider-controlled; the integration does not verify every occurrence or guarantee identical propagation to every detached override. One series operation can affect an unbounded number of occurrences and consumes one modify intent. Other occurrence references may need a fresh query after provider identity changes.

Within retained detail availability (five days by default), select exactly one series source with `preflight_rollback`, for example `{"change_ids":["<source-change-id>"]}`. Review the complete inverse preview and route each step using its `commit_tool` field: version-4 series recovery uses `commit_series_rollback`; ordinary recovery uses `commit_rollback`. The hint is not authority, and each tool checks its exact native-authenticated contract. Series inverse reapplies only the masked prior defaults and any masked raw alarms to the same current pattern. It does not reconstruct overrides, exclusions, previous structure, identities or earlier split segments.

Mixed series/occurrence or multiple-source series undo is rejected. Any later integration execution intent in the same calendar blocks series inverse; ambiguous legacy independence also blocks it. Ordinary occurrence recovery cannot cross a newer series-default edit in that calendar. These conservative guards remain after detailed data expires. Unresolved outcomes block conflicting or insufficiently evidenced writes; use the [journal assessment workflow](#plugin-journal-assessment) with explicit user evidence. After uncertain transport, inspect the original nonce through `get_change_status` without retrying or preparing a replacement attempt.

The [architecture contract](architecture.md#current-pattern-default-field-modification) records the exact capability, version-4 payload and lineage design. Synthetic contract/discovery tests do not establish real provider propagation, first-anchor identity changes, exception behavior, alert delivery or host presentation; those remain separate scoped live validation tasks.

## Future occurrence default fields

Version-5 future default-field modification is implemented in the 22-tool floor-7 helper and validated with synthetic providers. Live provider behavior is not comprehensively verified. Do not run these examples against actual calendars during unattended tests. Cutoff termination is a separate version-6 contract below; the version-5 tools reject it.

Query the exact intended future non-detached occurrence and use its opaque reference. The selected occurrence is included. Request a nonempty subset of title, notes, plain location and alerts:

```json
{"action":"modify","scope":"future","event_id":"<exact-future-occurrence-id>","fields":{"title":"Updated future planning title","alerts":[{"relative_minutes":-15}]}}
```

The selected start must be strictly later than native now, and its occurrence identity must equal that start. Elapsed/ongoing events, detached or ambiguous references, no-op requests, count-ended patterns and multiple recurrence rules are rejected before intent. The first subset accepts exactly one supported unbounded or date-ended rule. Dates/times, timezone, all-day, recurrence and calendar moves cannot be changed. Omitted alerts preserve complete alarms; `[]` clears them. Existing writable-calendar, invitation, structured-location and unsupported-alarm guards apply to the selected occurrence and original first anchor.

The complete version-5 preview signs the selected full `before`, selected-rooted full `after`, `future.boundary`, the complete original `future.first_anchor`, sorted `future.changed_fields`, and four exact `future_default_fields` limitations. Expiry is capped at the selected start. Pass the returned complete unchanged preview through `commit_future_modify` under the host confirmation policy; legacy and version-4 commits reject it. The broker checks native time before claim and the provider checks it again immediately before its one `.futureEvents` save. A clock crossing after durable intent is conservatively unknown; no automatic retry or compensation occurs.

EventKit may split the provider pattern and change identities and recurrence end metadata. Earlier occurrence fields and times are outside the request; earlier split segments are not merged. Native verification checks the directly saved tail boundary and, when applicable, the exact earlier first-anchor witness. It does not enumerate every past occurrence or guarantee detached-override propagation. Only the selected boundary reference can be rebound to the verified direct-save identity; other stale sibling references require a new query.

To recover, select exactly one original retained applied future change alone through `preflight_rollback`. Its original boundary must still be strictly future, the current tail and first anchor must exactly match the retained verified segment, and later possibly related intents block recovery. Submit the exact returned step through its `commit_tool:commit_future_rollback`. The inverse restores only masked prior defaults and exact retained masked alarms to that same future segment. It does not merge segments or reconstruct recurrence topology, overrides, exclusions or identities. Recovery can become unavailable before the normal detail-retention expiry. Mixed selections, recursive inverse recovery and choosing a later boundary automatically are unsupported.

Every future intent consumes one modify charge and can affect an unbounded number of occurrences. Its native conflict footprint is deliberately incomplete at the trusted calendar boundary, so an unknown future outcome blocks every same-calendar mutation; independent other calendars remain subject to existing evidence checks. Applied or expired future history also remains a recognizable series boundary for conservative recovery crossing checks. Original payloads and nonces remain immutable and replay returns the stored outcome without another save or charge.

The current source recognizes recovery floors 2 through 7 and retains exact older capability objects as minimum contracts. Version-5 publication requires all dependent capabilities and recognized floor >=4. Older helpers retain only their independently verified contracts. Keep encoding 2 and authoritative history intact; repair forward after a migration commits. Build/startup/capability probing and metadata verification request no Calendar access.

The [exact architecture contract](architecture.md#future-default-field-modification) distinguishes source behavior from deployed behavior. Synthetic verification does not establish iCloud propagation, complete past/exception preservation or ChatGPT/iPhone presentation. The user-approved/readback-verified `ask_before_writes` host mode does not bypass the separate OpenAI safety refusal or prove a fresh human click.

## Stop a pattern from a cutoff and create an independent recovery copy

Version-6 cutoff termination and independent-copy recovery are implemented and synthetically validated. The current writer is floor 7 with the exact v6 minimum-floor-5 capability; live provider validation remains incomplete. Fresh all-day termination/copy recovery is unsupported in every timezone; timed v6 behavior remains supported. No actual Calendar data or production services are part of unattended validation.

Identify one non-detached reference in the exact current provider pattern. Request termination with no fields and one explicit cutoff form:

```json
{"action":"delete","scope":"future","event_id":"<current-pattern-reference-id>","cutoff":{"date":"2026-11-02","time_zone":"Europe/London"}}
```

```json
{"action":"delete","scope":"future","event_id":"<current-pattern-reference-id>","cutoff":{"at":"2026-11-02T10:00:00+00:00"}}
```

A date means inclusive midnight in that explicitly named timezone; invalid/ambiguous/nonexistent midnight is rejected. An instant requires an explicit offset. The native broker queries the complete bounded current-group window from cutoff through 366 calendar days and signs the earliest eligible default boundary at/after cutoff. The reference need not already be that boundary. An excluded date has no default occurrence, so a later existing default may be selected; a known detached/moved candidate before that boundary instead requires separately scoped occurrence handling. No result means no boundary observed in that bounded window, not proof the pattern ended. If the earliest eligible default is elapsed or ongoing, preflight rejects without silently advancing it.

Review the complete version-6 preview: supplied cutoff, resolved UTC cutoff, inclusive native boundary, full boundary/reference/first-anchor snapshots, exact selection window, `removes_entire_current_pattern`, canonical typed `copy_recurrence` and all seven `independent_tail_copy` limitations. Submit the unchanged preview through `commit_future_delete` under the host confirmation policy. Older routes reject it. Expiry is capped at the boundary; native commit reselects the same exact boundary/state before claim and checks time again immediately before its one `.futureEvents` removal. A crossing after intent or failed verification is conservatively unknown without retry or compensation. A true whole-pattern flag permits removing the entire not-yet-started current pattern; it does not permit historical/full-series deletion.

Only a single supported simple daily/weekly/monthly/yearly unbounded or date-ended rule with an exact public typed-constructor match and preserved default phase is accepted. Count ends, unsupported selectors, multiple rules, nil timezone and ambiguous/moved boundary semantics are rejected before deletion. Phase checks preserve the named-zone default wall-clock start/end, calendar-day duration and applicable weekday/month-day/leap-day semantics; normalized substitutes that cannot start an honest copy are rejected. No custom recurrence end is assigned during deletion.

The provider controls termination and detached overrides/exclusions. Earlier fields/times, other split segments and independent copies are outside scope. Known and unenumerable detached/moved events can survive, including beyond the bounded window; this operation does not prove that every event after cutoff disappears. Readback checks exact boundary absence and the exact preserved earlier anchor with only allowed provider end shortening, or exact original-anchor absence when the whole not-yet-started pattern was removed. That witness is not exhaustive topology proof. No original opaque ID is rebound.

For recovery, inspect retained history, then select exactly one original applied version-6 termination alone with `preflight_rollback`. List/get remains metadata-only and its eligibility is provisional; recovery preflight and commit check exact original boundary absence, unchanged verified truncated prefix or whole-pattern absence, retained source/lineage and no conflicting later intent. Permission/ambiguous lookup errors never count as absence. The normal five-day default detail retention applies. Unlike version-5 inverse fields, this new-copy option can be reviewed after the original boundary has passed.

Submit the complete returned preview through its `commit_tool:commit_future_restore`, with a separate host write confirmation. It signs `action:create`, the original exact cutoff/boundary object, full retained creation fields plus canonical recurrence, complete raw alarms/supported metadata, current prefix witness and one-source digest/restoration binding. Both routes refresh full native time/TTL checks immediately before durable claim. The restore creates one new independent recurring series with new provider and opaque identities from the original deleted boundary, rejecting a returned identity already bound in the registry. It never reattaches/merges the prefix, restores exclusions/overrides or rewrites original IDs. Skipped occurrences can reappear, surviving moved/detached events can duplicate, and dates now in the past can be recreated. These risks are signed in the original delete and restore previews; this is limited copy recovery, not full undo.

Termination consumes one delete intent and can remove unbounded occurrences. Restore follows normal creation policy, can add unbounded occurrences and does not refund the original delete charge. Source linkage is consumed once, including an unknown restore; recursive/mixed recovery is rejected. Both v6 intents use incomplete trusted-calendar conflict footprints and remain recognizable future boundaries after detail expiry. An unresolved delete/restore blocks same-calendar mutations; other calendars still require existing disjoint evidence. No automatic retry, compensation or reconciliation is introduced.

The current writer uses floor 7; v6 keeps minimum floor 5 and older series/future capabilities keep minima 3/4. Exact capability checks are required. Preserve encoding 2 and authoritative history, and repair forward after migration commits. `commit_future_delete` advertises destructive write semantics; `commit_future_restore` advertises creation semantics like `commit_create`, because it creates a separate series without modifying the prefix. These annotations describe actions and do not bypass host safeguards.

Source/synthetic verification and the [exact architecture contract](architecture.md#cutoff-termination-and-independent-tail-copy) do not establish live iCloud normalization, complete detached/topology behavior or ChatGPT/iPhone presentation. Those remain separately scoped live validation tasks. The separate OpenAI safety gate remains unchanged.

## Multiple event alerts

Creation accepts a complete `fields.alerts` list, alongside the required event fields. For example, this fields value requests alerts thirty minutes and five minutes before the event:

```json
{"title":"Alert fixture","start":"2026-11-02T10:00:00Z","end":"2026-11-02T11:00:00Z","alerts":[{"relative_minutes":-30},{"relative_minutes":-5}]}
```

For an existing event, read its complete native alarms in `get_event` → `event.details.alarms`, then preflight `action:"modify"`, `scope:"this"` and its exact `event_id`. Submit the complete desired replacement list in `fields.alerts` to add, edit or remove entries. These are separate example field values:

```json
{"alerts":[{"relative_minutes":-30},{"relative_minutes":-5},{"relative_minutes":0}]}
```

```json
{"alerts":[{"relative_minutes":-60},{"at":"2026-11-02T09:55:00Z"}]}
```

```json
{"alerts":[]}
```

An omitted `alerts` field preserves existing native alarms on modification. An empty list clears every alarm. On creation, omission defaults to no alerts. Each item has exactly one `relative_minutes` integer between -525600 and 525600 inclusive, or `at` with an explicit UTC offset; null, mixed forms, extra keys and canonical duplicate triggers are rejected. The maximum is ten replacement alerts. Negative relative values are before start, positive values after start, and zero is at start, matching [Apple's relative-offset alarm semantics](https://developer.apple.com/documentation/eventkit/ekalarm/init%28relativeoffset%3A%29). Relative values measure elapsed minutes, including all-day events and daylight-saving transitions; they do not promise a fixed local wall-clock hour across a transition. Absolute alerts retain their instant when the event start changes. Absolute and relative triggers at the same current instant are distinct and may coexist.

Explicit replacements create plain display/time alerts. They replace existing alarm sound, geographic and proximity settings as part of the complete list; omit the field to preserve richer supported native alarms. Events with unsupported email/procedure alarms remain blocked by the existing mutation eligibility checks. All existing event, occurrence, identity, stale-state, quota and durable-journal guards apply. Pass the complete native-authenticated preview to the matching commit tool under the selected host consent policy; host policy is not evidence of a fresh human click.

The gateway independently probes the resident helper's metadata-only `alerts_capabilities` contract. Only the exact supported response enables alert input and version-2 previews in discovery; an older helper keeps its legacy schemas and rejects alert requests before dispatch. Updating Python source alone cannot enable native alert support. A recurrence-capable helper issues version-3 ordinary previews, including alerts, while recovery remains version 2. Version-1 signed previews and encrypted history remain compatible; the change requires no storage migration. New recovery previews sign complete retained raw alarms separately in `rollback.alarm_restoration`, preserving supported richer alarms without the public replacement count cap.

## Retained history and recovery

Retained recovery is implemented and synthetically tested. Production recovery behavior is not comprehensively verified. The gateway probes the actual resident helper once with internal metadata-only `recovery_capabilities`. Only the exact supported storage/version/capability response enables the four ordinary recovery tools; dedicated series/future tools additionally require their exact independent capabilities and minimum recognized storage floors 3/4/5. An older helper keeps the original nine tools and rejects recovery dispatch as unavailable. A gateway/source restart alone cannot enable recovery, retention, or encrypted native storage on an older helper.

The upgraded broker captures complete execution payloads and observed results in encrypted per-execution detail storage. It retains integration modify/delete history for **five days by default**, with a fixed expiry captured for each record. The original before state, proposed change and observed outcome can be inspected while details remain available. This is integration history, not a backup or complete account-wide change feed: edits by Calendar, other apps and devices are outside it. Created-event details are encrypted and expire too, preventing event text from remaining indefinitely in duplicate journal/audit copies; history selection covers modifications and deletions.

To change the retention duration, place a complete protected version-1 file at `<gateway-state>/native-eventkit/recovery-policy.json` (or `native-synthetic` for fixtures), owned by the logged-in user with mode `0600`, inside the protected native directory. [The example](recovery-policy.example.json) uses:

```json
{"version": 1, "retention_days": 5}
```

`retention_days` is an integer from 1 through 365. There is no MCP setting, caller override or transport-selected policy path. Changes apply to newly captured records; existing expiries remain fixed and increasing retention never resurrects expired details. New detail capture is clamped to the persisted retention high-water mark after a wall-clock rollback, so newly captured history does not expire immediately. Execution/quota timestamps keep their existing semantics. Missing configuration uses five days; malformed or unsafe configuration fails closed. Unresolved `intent_recorded`/`unknown` executions and the source history needed for an unresolved recovery are held beyond expiry until evidence-based reconciliation permits expiry. Minimal journal outcomes, consumed nonces, lineage, audit integrity records and destructive quota claims remain after detailed data expires. The operational identity registry also retains native identifiers, occurrence identity and `known_start` timestamp metadata needed for safe event lookup. Expiry covers encrypted change payload/result/legacy-audit event details; it does not erase every event-related identifier or timestamp. Expiry removes the active store's per-record decryption key at startup, before operations, and on a metadata-only resident maintenance check every 60 seconds; a stopped helper expires overdue details on next startup. Backups, exported data, SQLite remnants, filesystem snapshots and SSD history need their own retention and are not claimed erased.

In ChatGPT, use `list_changes` to browse retained modifications/deletions and `get_stored_change` with a returned `change_id` to inspect its complete before/proposed/observed states and eligibility. Listing supports optional `since`, `until`, `action`, `event_id` and `include_expired`, plus `limit` from 1 to 100 (default 50). Follow `next_cursor` until null, repeating the original filters on each page: pagination is tied to a stable snapshot and one page never means all. Expired entries retain metadata but return null sensitive details; unknown or otherwise unsupported entries explain why they cannot be recovered automatically.

For selected changes, call `preflight_rollback` with unique `change_ids` (maximum 25) alone. For all matching changes within that bound, use `all: true` and optional history filters. A selection exceeding 25 sources or the complete preview-size bound fails with batching guidance; it never silently drops sources. For a larger **all** job:

1. Collect every matching `list_changes` cursor page and freeze the complete newest-first ID inventory and total count.
2. Expose blocked/expired entries and obtain the intended supported subset; do not silently skip them or call the first page all.
3. Preflight explicit batches of at most 25 newest-first source IDs. Inspect every returned step and limitation.
4. Commit each exact `steps[].preview` in returned order through `commit_rollback`, under ChatGPT's normal confirmation policy. Finish the current batch before preparing the next.
5. Stop on any failure or unknown outcome, inspect the original nonce with `get_change_status`, and refresh remaining previews after the outcome is safely resolved. Report completed and remaining source IDs.

The broker groups compatible history for the same event and signs each complete step, including its exact source IDs, selection binding and restoration details. An external edit between recorded changes breaks the required history bridge and blocks both grouped undo and an earlier sequential undo; expired bridge evidence can block an older source whose own details are still retained. Recovery is a new create or modify with current identity, stale-state, eligibility, quota and durable-journal checks. It is not atomic across steps or batches. An external edit can invalidate a preview. Delete recovery creates a new event and cannot reproduce native/provider IDs, timestamps, provenance or invitations. Supported writable URL, alarms, structured location and availability are restored; unsupported restoration is rejected with a reason. The recurrence release permits a retained recurring/detached occurrence deletion only when its version-3 source signed the exact standalone-copy limitation; recovery signs the same limitation and recreates an independent nonrecurring event, leaving the series exclusion intact. Legacy recurring deletions lacking that contract remain blocked. Unknown outcomes cannot be automatically rolled back. The scoped guard blocks conflicting writes and recovery dependencies; an independent existing native group needs complete disjoint evidence and a qualifying prior registry witness. Legacy or ambiguous evidence uses conservative calendar/global fallbacks. Original nonces stay consumed. For a supported recurring/detached occurrence modification, recovery restores the displayed event fields while preserving the current occurrence/series structure; it cannot undo historical detachment or reattach the occurrence to its former series inheritance. This limitation appears in the signed preview.

Local tooling uses the same retained history through the authenticated gateway:

```sh
./scripts/calendar-mcp changes list --port 8765 --limit 50
./scripts/calendar-mcp changes list --port 8765 --cursor '<next_cursor>'
./scripts/calendar-mcp changes show '<change_id>' --port 8765
./scripts/calendar-mcp changes open --port 8765
```

Add `--state-dir <gateway-state>` when using a nondefault state. `changes open` verifies recovery discovery and sends only `{"op":"open_changes"}` to the existing broker's protected deterministic local socket; the socket lives under `<protected-Darwin-user-temp>/cmui-<first20-SHA256-canonical-native-path>/s`, inside a strict owned `0700` directory with an owned `0600` socket and native peer-UID validation. This fixed derivation supports long state paths. The command does not start another state owner, submit a preview or approve anything. The standalone native window lists, filters and shows history, supports selected changes or **Select all matching**, traverses all snapshot pages, and displays exact batches for review. Its native Apply control captures the displayed preview and executes within the broker; no Terminal approval, remote approval API or caller-provided approval boolean is involved. Local actions use `approval_source: local_native_ui` and `approval_evidence: native_control_activated`, distinct from MCP `chatgpt_host_policy` / `not_provided`. Neither path claims a backend-verifiable fresh ChatGPT human click. The gateway and broker must already be running in the logged-in desktop session; use `--backend synthetic` only for isolated fixtures.

Storage-v2 migration is native, fail closed and transactional. It verifies legacy audit integrity, encrypts legacy details, preserves all consumed nonces, unresolved intents and quota claims, and starts the minimal v2 audit chain with the legacy tail/count, conversion checkpoint and integrity-bound legacy manifest. Retained event-bearing legacy audit bodies are encrypted under the same expiring execution keys. Original capture times govern migrated expiry. Migration does not reconcile a pre-existing unknown; such outcomes retain scoped conflict protection with conservative calendar/global fallbacks until resolved. Complete stopped-state backups and their keys remain sensitive and authoritative history must never be replaced by an older copy. Migration/expiry does not repair a missing or stale backup history. Once a v2 checkpoint commits, do not restart a legacy helper or restore an older database to bypass cleanup; keep jobs stopped and repair forward with the upgraded helper. A persisted cleanup-pending flag and native v2 write constraints fail closed across interrupted cleanup or attempted legacy writes.

## Civil all-day dates: version-7 source feature

Fresh all-day deletion, cutoff termination and copy restoration are unsupported for every timezone, including named-zone events. Timed version-6 behavior is unchanged. Exact recorded-nonce replay still precedes fresh-operation rejection.

Version-7 civil all-day dates are implemented in the current floor-7/22-tool helper, with synthetic validation. Source tests use synthetic providers only. Existing unknown executions, immutable payloads/results, consumed nonces and unresolved conflicts are never relabeled, reconciled, bypassed or retried by this feature.

For a nonrecurring floating all-day event, supply `fields.all_day_dates` with strict Gregorian `start_date` and `end_date_exclusive`, spanning 1–366 calendar days. The exclusive end is the first excluded date; a single day ends on the following date. Create requires calendar_id/title; date edits require one nonrecurring, non-detached, nil-timezone all-day event_id. Use scope this. Do not mix the date object with start/end/time_zone/all_day/recurrence. Optional title, notes, plain location and complete alerts retain existing limits and safety guards. Metadata-only edits stay on the preserve-only v3/v4/v5 contracts. All-day deletion/copy recovery and cutoff termination in every timezone, recurring structural changes, calendar moves and timed/all-day conversions remain unsupported.

A named-zone timestamp-style all-day create is validated under the old exclusive-midnight input rules, then converted into a fresh v7 floating preview. Nil-zone timestamp creation and timestamp date changes require the civil object. An unclaimed old structural all-day preview requires fresh preflight; exact old nonce replay is still checked first and returns its original outcome, including unknown.

The complete signed version-7 preview includes `all_day:{version:1,semantics:floating_civil_dates,projection_time_zone,before,after,write_end:inclusive_last_second,readback_ends:[exclusive_midnight,inclusive_last_second]}`. The native default timezone is a projection coordinate system; the event remains nil-timezone/floating and the caller cannot select a substitute zone. Strict Gregorian labels use years 0001–9999 and integer proleptic day counts independently of Foundation's historical calendar cutover. Native projection must round-trip those exact labels and midnight instants; unsupported historical Foundation mappings fail closed. Native timezone projection also rejects ambiguous/nonexistent midnight and overflow. Full raw before/fingerprint is unchanged; full after signs the actual assignment: projected start midnight and exclusive-end midnight minus exactly one second, all_day true/time_zone null, plus requested alert intent.

Commit_create/commit_modify accept only their corresponding v7 action with scope this; dedicated v4/v5/v6 tools reject it. Native code binds and rechecks the actual default projection zone before claim, before provider entry and during direct-identity readback. Exactly two raw ends are acceptable for the same signed civil interval: exclusive midnight or the preceding last second. An extra ending day, fractional endpoint, wrong start, nonnil timezone or changed metadata/alarms fails verification. The actual observed record and fingerprint are stored unchanged. A post-intent mismatch remains unknown with no retry or compensation.

Fresh creation has a narrow plain-location verification rule. For fresh v7 creation, plain location readback accepts null or exactly `{title:<signed location string>,radius:"0.0"}`, including empty signed text. Coordinates, extra keys, title differences and alternate/nonzero radii fail verification. The actual wrapper and fingerprint remain unchanged in results/history; modification/inverse structured-location preservation remains exact. Existing unknown executions retain their original results, replay protection and conflict guards. This source fix adds no tools, preview/capability fields, storage upgrade or automatic recovery.

One-source inverse of an applied original v7 modification signs the retained original civil interval/metadata and complete raw alarms through ordinary commit_rollback. It preserves current identity and unrelated properties, requires the original projection zone still current and signs the exact limitation that raw endpoint style is not guaranteed. Mixed/multiple sources and creation recovery are unsupported. Existing retention, stale/source checks, linkage, quota and journal protections apply.

The all_day_dates capability has minimum floor 6; the current writer is floor 7. Older capability minima 3/4/5 remain exact. Native Foundation owns temporal projection; Python forwards the complete unchanged signed payload. Encoding 2 and authoritative history remain preserved. Repair forward after migration commits.

## Floating all-day metadata preservation: source fix

Floating all-day metadata preservation is implemented and synthetically validated. It requires no civil-date interpretation or structural scope; live provider behavior remains separately scoped.

Existing nil-timezone all-day records can use supported title, notes, plain location and complete-alert edits only when start, end, timezone and all-day state remain exactly the observed raw values. Ordinary occurrence edits, current-pattern/version-4 and future/version-5 default edits, and their supported inverse paths use that same preservation rule. Metadata edits do not infer midnight, substitute a display timezone, normalize endpoints or rewrite unrelated raw temporal state. Existing structural, invitation, alarm, location, stale-state, quota and journal guards remain authoritative.

Creation, deletion/copy recovery, date/time or timezone edits, timed/all-day conversion and version-6 termination remain unsupported for nil-timezone all-day records in this fix. A separate civil-date contract is required to interpret or correct dates. An earlier all-day creation became unknown; its original unknown result remains retained after the separately authorized user attestation documented above. This fix does not retry, reinterpret or automatically reconcile it. It does not solve provider end-representation normalization during creation.

## Event scope, recovery and private state

Query windows are bounded to 93 days and 1000 events. IDs are opaque integration references; do not substitute titles/times for identity or guess a new ID when a provider changes one. Missing/ambiguous identity needs a fresh query. The recurrence release supports new series creation (`scope:"series"` plus a typed recurrence rule); modification/deletion addresses one identified event or occurrence (`scope:"this"`). The installed helper supports the restricted version-5 future default-field subset and separate version-6 cutoff-termination contract documented above. User-directed structural series edits, arbitrary historical/full-series deletion, recurrence-rule changes and invitation/organizer mutations remain unsupported. Restricted cutoff termination is the separate version-6 contract above. Current-pattern title, notes, plain location and alerts use the dedicated version-4 tools described above. A new recurring/detached occurrence deletion requires version-3 signed standalone-copy recovery disclosure; older contracts remain blocked. See [individual and recurring events](#individual-and-recurring-events) for source/deployment distinctions and examples. The installed helper supports nil-timezone all-day metadata/alerts with exact raw temporal preservation and the narrow v7 civil-date creation/correction/inverse contract above; fresh all-day deletion, copy restoration and cutoff termination are unsupported in every timezone. Email/procedure alarms and location edits that cannot preserve an existing structured location remain rejected.

Legacy timestamp inputs and new timed events use the `Europe/London` default when no named zone is supplied. Timestamp inputs require explicit offsets; UTC `Z` is accepted, while a local numeric offset must match the named timezone. Legacy all-day timestamp creation uses exclusive local-midnight input ends before conversion to v7. The v7 civil-date object has no caller zone or offset: `end_date_exclusive` is the first excluded Gregorian label, native default-zone projection supplies the adapter coordinates, and the signed assignment uses the preceding last second. Events remain floating with nil timezone. Raw EventKit snapshots retain their observed representation. Availability is a snapshot, not a reservation. Provider concurrency and DST/recurrence edges are not exhaustively verified.

Normal writes have no Terminal approval or remote approval endpoint. A host denial never reaches the broker, and remembered host policy may suppress a fresh prompt. Calendar text is untrusted data. Audit covers native-received commits/configuration/recovery, not every host denial or other calendar client's edits; stateless preflight issuance is not logged.

After an uncertain commit/connection loss, **do not blindly retry or create a replacement preview**. Reconnect/restart if necessary, then call `get_change_status` with the original nonce. Consumed nonces remain consumed. Unknown outcomes retain scoped conflict protection until explicit evidence-based user assessment, including conservative calendar/global fallbacks when evidence is incomplete; an uncertain future operation can hold the entire calendar. Use `list_unresolved_changes` and `get_stored_change`, or `get_change_status` with the original change ID, to inspect the journal. Obtain the user's explicit applied/not_applied assessment and evidence before `preflight_reconciliation`, then submit the exact reviewed preview through `commit_reconciliation` under normal host write confirmation. This changes only the journal, provides no provider verification and never retries Calendar data. Never infer or approve an assessment automatically. If the journal tools are missing in the host, refresh the calendar plugin tool definitions; no Terminal reconciliation is required for this workflow.

Deployed transport hardening rejects malformed Unicode strings/keys and nonfinite numbers before native submission. A native `invalid_arguments` response explicitly states that no request was submitted and leaves a healthy broker available; it does not attest any previous uncertain outcome. This change is deployed; live Calendar validation remains separate.

The deployed stdio adapter also rejects invalid request IDs safely, handles malformed initialize parameters and contains invalid gateway result serialization while allowing subsequent framed requests. If a response fails after possible write submission, its error retains the no-retry guidance above; a continuing connection does not establish the write outcome. This adapter change is deployed.

Deployed local-window IPC uses Darwin's protected per-user temporary base and ignores `TMPDIR` and public legacy endpoint preclaims. An unavailable optional native window reports `local_ui:false` while the broker and four remote history/recovery tools remain usable. These changes are deployed; remote recovery still uses exact previews, native journal checks and the host consent policy.

Native accounting hardening is deployed. New rejected/replayed commit observations use exact durable counters in fixed operation/reason/origin buckets, with at most one dirty cumulative hash-chain checkpoint per persisted effective hour. Quota denials are counted once; accepted policy adoption and quota charges remain separately audited. Replays return the same recorded outcome without a new provider write or charge. Counters expose total/checkpointed/pending values through internal metadata-only `commit_observation_status`; pending rows are mutable operational accounting, not per-attempt chain evidence or proof of a fresh click. Restart/backward clock movement cannot reset counts or accelerate checkpoints, and counter corruption/exhaustion fails closed. The additive upgrade preserves all existing audit/legacy rows, execution payloads/outcomes, consumed nonces, unresolved evidence, detail keys and quota claims.

The deployed retention implementation indexes expiry candidates and unresolved executions. Each operation still persists the retention high-water mark before the indexed due check; exact expiry, ancestor holds and no-resurrection semantics are unchanged. Normal checks avoid reconstructing resolved history; due cleanup may still process many expired records.

## Upgrade an existing installation

Use a reviewed maintenance plan for the installed state and ownership; fresh-install commands are not an upgrade procedure.

1. Build, sign, review and test the replacement privately before touching the settled app or running services.
2. Pause the owned monitor and close the owned tunnel/adapter intake. Drain in-flight native work before stopping the gateway, then confirm native exit and state-lock release before any offline migration.
3. Preserve a stable baseline of authoritative history, schemas, identities, ciphertext/keys, consumed nonces, quotas, audit and receipts, plus protected configuration and restart-budget history. Quiescing owned intake is not atomic exclusion of independent local clients; detect arrival races and keep intake closed if preservation checks fail.
4. Migrate only with the reviewed compatible helper and replace the signed app at the settled path. Once migration commits, repair forward: never restart an older incompatible helper or restore older authoritative history to resume writes. A migration is not a Calendar retry or reconciliation.
5. Start the new gateway and verify the exact resident executable/ownership, actual permission metadata and expected tool schemas/instructions. Compare authoritative history and protected configuration/budgets, permitting only reviewed floor/maintenance-clock changes. A replacement signature may need a separately attended OS grant; do not request it automatically.
6. Reconnect the same owned runtime/profile/environment reference, verify health and resume the monitor last. If checks fail, leave intake closed and repair forward; do not silently fall back to old code or state.

## Private state storage

Protect state, SQLite/associated files, exports and backups as sensitive before/after data (`0700` directories, `0600` files). Gateway/adapter logs omit credentials/request bodies. Keep raw HTTP payload tracing off in the tunnel client. `.gitignore` excludes runtime state, environment/credential files, keys, databases, logs and downloads; that is defense in depth, not a substitute for reviewing staged files before commit.

Recovery AES keys (`execution_keys`) and the preview-signing secret (`metadata.signing_key`) currently reside in the same SQLite database as the protected history. Copying that database also copies its decryption keys: encrypted detail storage supports bounded retention, not isolation from someone who can read the database. The gateway token and tunnel runtime env file are protected files, not Keychain items. Directory/file modes and the trusted local user are the security boundary; never treat a copied database or credential file as safe to share.

For ordinary stopped-state maintenance below—credential rotation, backup/restore, key rotation or exceptional local reconciliation—run `./scripts/calendar-mcp service uninstall` if the optional service is installed. This preserves its private configuration and native history while preventing the monitor from restarting components during maintenance. Confirm the gateway, broker and managed tunnel have stopped. After maintenance, re-render only if configuration changed, then explicitly `service install` to resume login startup and monitoring. For a manual deployment, stop the tunnel and gateway yourself and restart them after maintenance.

To rotate the gateway credential while stopped, securely remove or archive only the old protected `gateway.token`, run `init`, then resume using the same native state through either service installation or the manual startup commands. The new token's local SHA-256 binding rotates native signing key/key ID/generation while preserving journal history. A running gateway retains its old token until stopped. Revoke/rotate the tunnel credential separately and securely update the approved local env file; service installation or a manual managed reconnect reloads its environment reference.

The current helper uses compatibility floor 7 and version-2 encrypted detail encoding to implement the bounded detail retention described above while preserving minimal replay/audit/quota history. Its pre-migration legacy format retained details indefinitely. There is no audit export/purge, automatic backup or history-merge CLI. Back up the entire protected native state only with the broker fully stopped, including both policies, encrypted details and their keys, journal, immutable quota ledger and effective-time watermark. Never copy/overwrite a live SQLite database or manually delete audit/journal/quota rows. Never replace newer authoritative history with an older backup and resume writes: later nonces, intents and quota charges would be missing. Preserve or recover the newer immutable execution/quota history first; if it is unavailable, keep writes stopped for operator recovery. Key rotation cannot reconstruct missing history. For a valid stopped-state restore with authoritative history retained, invalidate old preview authentication before restarting:

```sh
"$PWD/build/Calendar MCP Helper.app/Contents/MacOS/CalendarHelper" \
  --rotate-keys --state-dir "$HOME/Library/Application Support/Private Calendar MCP/native-eventkit"
```

This is local state maintenance, not EventKit access. A backup cannot recover external writes made after it was taken; inspect possible outcomes and retain/recover their newer native history before resuming writes. Audit hash chains are tamper-evident relative to a trusted checkpoint, not tamper-proof against the same user rewriting history.

For exceptional local operator attestation instead of the normal MCP journal workflow below, stop the gateway and inspect independent evidence before using the local command:

```sh
"$PWD/build/Calendar MCP Helper.app/Contents/MacOS/CalendarHelper" \
  --reconcile --state-dir "$HOME/Library/Application Support/Private Calendar MCP/native-eventkit" \
  --nonce ORIGINAL_PREVIEW_UUID --outcome applied \
  --evidence "Brief factual inspection evidence without sensitive details"
```

Use `not_applied` only when supported by evidence. A real TTY and typed nonce confirmation are required; this performs no Calendar mutation, records operator attestation and leaves the nonce consumed. It is not a normal write-consent surface. Avoid sensitive evidence in shell history/process arguments. The state lock excludes a running broker.

## Stop and remove

If the optional service is installed, run `./scripts/calendar-mcp service uninstall` first so its monitor cannot restart components during removal. Otherwise stop the managed tunnel with `runtimes stop <alias>` and stop the gateway gracefully (Ctrl-C for a foreground process). Remove the plugin/local MCP configuration and revoke the tunnel runtime credential if no longer needed. Retain or securely dispose of protected state/backups according to audit needs; deleting them loses history and changes installation identity. Revoke the helper's Calendar access in macOS Settings if it should no longer read calendars. Deleting source alone does not revoke OS or tunnel permissions.


## Plugin journal assessment

The source supports three journal tools when the native helper independently reports the exact journal-assessment capability object at a recognized actual recovery floor >=6: `list_unresolved_changes`, `preflight_reconciliation` and `commit_reconciliation`. The current helper publishes 22 tools, retaining the existing nineteen contracts. Refresh the plugin tools to expose the three additions. This workflow uses ChatGPT native write confirmation and requires no Terminal editing or local TTY reconciliation.

1. Browse `list_unresolved_changes` and follow each `next_cursor` until null. Inventory includes unknown creations and recovery attempts as well as modifications/deletions. Rows resolved between pages can disappear; the cursor is not a frozen inventory.
2. Inspect the selected source with `get_stored_change`. Obtain the user's explicit assessment of whether that earlier execution was applied or not applied, with supporting evidence. Do not infer success from a transport error or label the assessment provider verification.
3. Call `preflight_reconciliation` with exactly that source `change_id`, `outcome: applied|not_applied` and nonblank `evidence` of at most 2000 Unicode scalars. Review the complete original execution, original unknown result, assessment and all three signed limitations. No Calendar access or pending workflow occurs.
4. Submit the complete unchanged authenticated preview through `commit_reconciliation` under the host's write-confirmation policy. A fresh preview expires after ten minutes and requires the source still to be exactly unknown/unchanged. The receipt records `resolution_source:user_assessment` and `verification:not_performed`. Host policy is not proof of a fresh human click.

This changes only the integration journal. It never changes Calendar data, retries or compensates for the original operation, or enables automatic rollback. The consumed original nonce, unknown evidence and charged quotas remain retained under existing retention rules. Resolution may clear a related-write conflict, after which any intended Calendar change still requires a separate fresh exact preview. The new receipt claim survives source-detail expiry: repeating the identical authenticated preview durably counts the replay and returns the same receipt, including after preview expiry or process restart, while binding/key changes still fail authentication. If assessment transport is uncertain, replay the exact same authenticated preview for its stable receipt. Use `get_change_status` with the original source `change_id` to inspect that execution; the reconciliation nonce is not a Calendar execution nonce. Do not create a fresh assessment or retry the Calendar operation. A changed preview cannot reuse its nonce. If another assessment has resolved the source, inspect the current status instead of substituting a new source or assessment. See the [native trust boundary and transaction contract](architecture.md#plugin-journal-assessment).


## Native non-execution outcomes (deployed)

The deployed floor-7 helper can return `state:not_applied` only when native leaf instrumentation proves the provider save/remove API was not entered and the terminal result plus `write_not_applied` audit committed atomically. Its exact version-1 `execution_evidence` says `provider_mutation:not_entered`; `diagnostic` contains only a fixed stage/code. A provider error message or a user-assessed `reconciled/not_applied` result is not this proof. Existing unknowns are unchanged, and every failure after API entry or without native proof stays unknown.

For a native `not_applied` result, inspect the diagnostic, correct the underlying problem if needed, then request a fresh exact preview and the normal write confirmation. Do not resubmit the consumed preview expecting a new Calendar write: it replays the terminal outcome. Its original modify/delete quota charge is retained. A failed inverse does not consume its source when non-entry was proven; prepare a fresh inverse review. Native batches stop and preserve earlier applied steps.

Writer floor 7 preserves encoding 2 and authoritative history/receipts. Real provider behavior remains subject to separately scoped live validation. Frozen older helpers must not be restarted against floor 7; they reject it. On any incomplete upgrade, keep services stopped and repair forward without restoring older journal state. The existing 22-tool schemas and capability minima remain unchanged. No Calendar operation, authorization request, automatic retry or incident reclassification is part of source validation or migration.

## Optional Reminders

The independently gated nonrecurring Reminders extension is disabled by default. Its [runbook](reminders.md) covers explicit foreground/service activation, separate OS access, two fixed resource adapters and distinct private tunnel/plugins (22 Calendar tools and 17 Reminders tools), separate local credentials and host catalog refresh, date/absolute-alarm limits, separate configurable retention/quotas and read-only local history. The feature is source-only; the settled installed helper, Calendar grant and runtime were not rebuilt or changed for this work. Do not apply activation examples until a separately authorized settled build/installation.


### Separate resource plugins (source implementation)

Calendar and optional Reminders share one gateway and native helper, but expose separate authenticated tool surfaces. Calendar keeps its existing tunnel ID, default stdio adapter and `gateway.token`; Reminders uses a distinct tunnel ID, fixed `stdio --resource reminders` adapter and independent `reminders.token`. A Calendar key cannot invoke Reminders routes/tools, and vice versa. No combined 39-tool plugin is configured. The [Reminders runbook](reminders.md#activation-and-os-access) includes explicit initialization and optional second-runtime service flags.

Existing version-1 Calendar service configurations remain valid. The optional exact `reminders_tunnel` object requires native Reminders opt-in and does not add another gateway/helper or LaunchAgent. It adds one independently tracked runtime to the existing monitor. Existing validated monitor history, restart attempts and backoff survive uninstall/render/install; unsafe or corrupt state fails closed rather than resetting a budget. Missing Reminders OS access does not restart Calendar; a reachable gateway with missing Calendar permission can still support the separate Reminders tunnel. Ambiguous runtime ownership suspends recovery. The new Reminders runtime additionally requires its official managed JSON profile and exact fixed target in a private directory; unsupported manual YAML or target drift fails closed. Existing Calendar profile handling is unchanged.

This split is implemented in source only; no existing runtime profile, installed app, grant, credential or ChatGPT plugin was changed by implementation/testing. Reusing an authorized protected tunnel runtime environment file is supported, but provisioning or connecting a new tunnel remains an explicit setup action.


Final source validation for the separate plugin boundary passed 374 strict native tests with zero failures/skips and 192 Python tests (189 passed, three existing packaged lifecycle skips), including actual raw-helper 22/17 discovery, cross-resource rejection, independent bindings, lifecycle and journal-assessment replay. The shared helper SHA-256 was `126fddc3920424a00d0f7541e3feb1dd57357613fdccd04fdf79af3e5cc06fa5`. No feature test was skipped. No live plugin/tunnel creation or connection, service change, credential migration, OS prompt or provider access was performed; this is source/synthetic proof, not deployment or live behavior proof.
