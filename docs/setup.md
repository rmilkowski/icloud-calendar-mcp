# Installation and operation

This is the authoritative installation guide. Use the fresh-install steps on a new Mac; use [Current Studio deployment](#current-studio-deployment) for the existing installation. **Do not rebuild an already authorized app just to follow this guide:** an ad-hoc signature change can reset its Calendar grant.

## Installation checklist

1. Configure the desired accounts in macOS Calendar, then install the prerequisites.
2. Build/sign the helper and run synthetic tests before requesting Calendar access.
3. Explicitly grant the bundled app full Calendar access on the Mac that will run it.
4. Initialize private state, start the local gateway and verify native authorization with `status`.
5. Download/verify the current official tunnel client, configure a private tunnel and restricted runtime credential, then start a managed runtime.
6. Add the tunnel in ChatGPT Plugins and verify a scoped read; separately verify each intended write path and its host confirmation.
7. Optionally stage and install the per-user login service and independent monitor after the manual setup works.

This integration reads **all calendars exposed by macOS**, including iCloud, other configured accounts, subscribed calendars and read-only calendars. It uses EventKit rather than collecting an iCloud password. Eligibility is checked per write target. It is a personal, single-user service; public ingress and public OAuth are not implemented.

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
swift test
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
  swift build --disable-sandbox
env CLANG_MODULE_CACHE_PATH=/private/tmp/calendar-mcp-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/calendar-mcp-swift-cache \
  swift test --disable-sandbox
env CLANG_MODULE_CACHE_PATH=/private/tmp/calendar-mcp-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/calendar-mcp-swift-cache \
  ./scripts/build-helper.sh
```

This disables SwiftPM's nested build sandbox, not the outer managed environment. The packaging script already selects this option. `swift build --show-bin-path` identifies the current toolchain's product directory; set `CALENDAR_MCP_TEST_HELPER` to that directory's `CalendarHelper` if test autodetection needs an override.

Automated tests use synthetic providers and temporary state. Build/test commands do not authorize real Calendar access. HTTP tests need temporary private loopback listeners. Default tests skip explicit LaunchServices app-launch tests; after packaging, opt into those synthetic-only lifecycle tests with:

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

Choose one loopback port and use it consistently for gateway, adapter and tunnel. The default is 8765. If it is occupied, choose another port; do not stop an unrelated listener.

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

Only literal `127.0.0.1` is bound. MCP uses authenticated POST `/mcp`; GET `/mcp` is 405 and there is no SSE subscription. Authenticated GET `/status` is local diagnostics, not an extra MCP tool. The stdio adapter reads the protected token itself; do not put it in client configuration.

EventKit IPC uses owned `0700` temporary directories and `0600` request/response/lifetime FIFOs. Only the gateway holds the noninherited lifetime writer. An independent native watchdog stops a broker even if execution/output blocks when the gateway dies. Native PID is diagnostic metadata and is never a signalling authority. No private TCC API or raw-executable production fallback is used.

For a manual restart, stop the existing gateway gracefully, rerun the same `serve` command with the same state/port/bundle, then check status. The optional service below makes login startup and bounded recovery an explicit installation choice; avoid duplicate gateways for one native state.

## 5. Install the official private tunnel client

Use the current [official Secure MCP Tunnel guide](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels) and its [latest release](https://github.com/openai/tunnel-client/releases/latest). Do not assume the version recorded in this repository is still latest.

1. Check `uname -m` and select the release's matching macOS architecture asset (`darwin-arm64` for Apple Silicon; select the release's published Intel asset for an Intel Mac).
2. Download its archive and published `SHA256SUMS` into an ignored `build/tools/tunnel-client/<release>/` directory. Check the exact archive filename/hash against the checksum file and GitHub's release-asset SHA-256 digest before extracting.
3. Keep the extracted client and accompanying bundled resources together. Check `file /path/to/tunnel-client`, `codesign --verify --strict /path/to/tunnel-client`, `/path/to/tunnel-client --version` and `/path/to/tunnel-client help quickstart`.

`shasum -a 256 /path/to/downloaded.zip` calculates the archive hash for comparison. Do not treat a successful download or a checksum from an unrelated filename as verification. No global PATH installation is required. The observed verified local client is v0.0.17 under `build/tools/tunnel-client/v0.0.17/`; substitute the newly verified path below on a fresh install.

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

On 24 October 2026 all 33 service tests passed. The full Python suite ran 57 tests: 54 passed and three explicit LaunchServices lifecycle tests were skipped. Existing native synthetic HTTP/stdio tests used the unchanged built helper. The new coverage includes strict credential parsing, metadata-only health, ownership conflicts, fake installation/rollback/uninstall, lifecycle locking, persistent recovery limits, busy/dependency handling, failed-state suspension and notification deduplication. Automated tests perform no real launchd registration. Separate authorized Studio installation/recovery checks are recorded below; an actual reboot/login cycle and visible desktop alert delivery remain unverified.

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

## Current Studio deployment

This dated operational note is separate from fresh installation. On 24 October 2026 the user authorized activating the optional service on the Studio. The gateway and independent monitor are now installed/enabled as the owning user's Aqua LaunchAgents; both jobs are registered. The gateway is reachable on **`127.0.0.1:18765`**, with its resident EventKit broker reporting `full_access`/raw 3, and the managed tunnel is healthy/ready. Private state remains `$HOME/Library/Application Support/Private Calendar MCP`; active launch diagnostics are under its protected `service` directory. Port 8765's existing listener was left untouched. The settled helper bundle was unchanged; do not rebuild it merely to operate the service.

The verified client is `build/tools/tunnel-client/v0.0.17/tunnel-client`, managed alias/profile is `calendar-studio`, and private generated profiles live under `.state/tunnel-profiles`. The runtime credential is referenced through the approved ignored `.state/tunnel.env`; no key values or account/workspace/tunnel IDs belong in this repository. The service's generated stdio command uses its configured absolute Python interpreter with `-m calendar_mcp stdio --state-dir <configured-state> --port 18765` and the repository as working directory. `scripts/calendar-mcp stdio --port 18765` remains an equivalent manual command with the default state; it is not the exact generated profile command.

For configuration changes, first uninstall the service using the maintenance procedure below, then render with **`--alias calendar-studio --profile calendar-studio --port 18765`**, the existing private tunnel ID, credential file, profile directory and settled helper, and explicitly install again. Do not start a duplicate manual gateway/runtime while monitoring is active.

```sh
./scripts/calendar-mcp service status
./scripts/calendar-mcp status --port 18765
./build/tools/tunnel-client/v0.0.17/tunnel-client runtimes status calendar-studio --json
```

For a planned stop or maintenance, run `./scripts/calendar-mcp service uninstall` first; stopping only the tunnel or gateway while monitoring is active is treated as an outage and can trigger recovery. Explicitly `service install` after maintenance to resume. To return to manual operation after uninstall, use the startup/connect blocks above with alias/profile `calendar-studio`, the existing private tunnel ID, the same profile directory/state and **`calendar_port=18765`**. Never use a returned native PID as a stop instruction.

Separate controlled stops verified real automatic recovery through natural periodic monitor checks: the owned gateway job restarted once after three failed checks, its old native broker exited through the lifetime mechanism, and the replacement reported full access while the tunnel remained healthy. A later official managed-tunnel stop triggered one reconnect after three failed checks while the gateway stayed healthy. The persistent budgets retained one gateway attempt and two tunnel attempts (initial startup plus controlled recovery), without reset. The gateway remained healthy across subsequent periodic checks. These checks queried only metadata and did not read or mutate Calendar data. The owning GUI session exists, but visible desktop notifications were not observed; an actual reboot/login cycle remains unverified.

The exact deployed stdio command initialized protocol `2025-11-25` and listed the expected nine tools, with zero `tools/call` requests. This verifies the local adapter/gateway protocol path, not refreshed ChatGPT discovery or a new Calendar read. Exactly one matching managed runtime was found. A read-only native journal/audit check retained two applied executions, zero unresolved executions, five audit records and a valid full chain; the settled helper hash was unchanged. No event details or opaque IDs are recorded here.

Historical validation on 23 October 2026: 16 native tests and the then-current 24 Python tests passed, including synthetic HTTP/stdio replay, credential rotation and explicit LaunchServices lifecycle/death tests. The production resident broker reported `full_access`/raw 3; a shutdown probe confirmed native exit. Managed tunnel status was healthy/ready, authenticated polling and MCP initialization succeeded. Earlier current-epoch `tools/list` was not observed, so no cached full tool-list observation is claimed; transport counters also included a dispatcher failure rather than universal success. The 24 October automated test counts and separate real service checks are recorded above; neither required rebuilding the helper.

The user verified an end-to-end real read on ChatGPT iPhone, then a test create and delete. Read-only journal/audit checks found create and delete both `applied`, matching `write_intent` → `write_applied` records, a valid five-record chain and no unresolved executions. Native completion follows EventKit read-back/deletion verification. The user confirmed a ChatGPT prompt before **create**; the delete prompt and complete UI fields were not independently verified. No event details, exact personal times or opaque IDs are recorded here. Real modify and provider/recurrence/timezone edge cases remain unverified. Backend audit does not provide cryptographic proof of fresh human approval.

A later write-safety rollout precheck on 24 October found one existing durable `unknown` delete, with a valid eight-record audit chain and no in-flight `intent_recorded` execution. This supersedes the earlier zero-unresolved observation above. Its nonce and history must be preserved; the unknown outcome blocks every fresh write until separate evidence-based local reconciliation. The rollout itself does not reconcile or retry it.

Write-safety production activation awaits approval. The original helper continues with unchanged full Calendar access; gateway and tunnel are healthy, both service jobs are registered, and the monitor is fresh. The deployed adapter initialized and listed nine tools with zero tool calls. Native state remains two applied executions, one unknown execution and the valid eight-record audit chain; no native migration, protected-state backup, helper replacement or Calendar query/mutation occurred during this handoff.

## Bulk modify and delete protection

The native source implementation adds cumulative protections for destructive changes. Current tool wording describes these as conditional on an upgraded broker: if preflight has no `safety` feedback, cumulative protection is not confirmed. The settled Studio helper described above must be deliberately rebuilt/deployed before it enforces this policy; editing source or placing a policy file beside an older helper does not enable it. Replacing an ad-hoc signed helper may require granting Calendar access to the replacement again. Preserve the current bundle until that rollout is authorized and verified.

Source validation passed all 29 native tests, including 13 new policy tests, and ran 58 Python tests with 55 passing and three explicit LaunchServices tests skipped. The quota/commit-recheck integration check used an isolated newly built synthetic helper. No authorized bundle, running service or Calendar data was changed.

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

The broker reloads the file during destructive preflight/commit, so a valid policy update needs no service restart. Preflight is advisory and does not adopt the file. A destructive commit durably adopts accepted policy revisions and audits their old/new values, hash and revision as local configuration, including if that commit is then rejected for insufficient quota. Initially, absence uses defaults; once a commit adopts an explicit file, removing it fails closed for new destructive calls rather than restoring defaults. Restore a complete valid protected file to repair that condition. Missing/invalid file errors use `write_safety_configuration`; exhausted limits use `write_safety_limit` with a safe retry time. These policy errors leave reads, status, creates and authenticated replays available; the existing unresolved-intent guard still blocks every new write. Native database corruption/migration errors can still prevent startup. Raising or lowering limits never resets the durable usage ledger, even if the file is changed back. Native startup backfills existing durable modify/delete intents during upgrade. Restarting, credential rotation and reconciliation also preserve counts and the effective-time watermark used to clamp backward clock movement.

For a larger intended job, identify the exact changes, inspect the `safety` usage returned by a relevant `preflight_change`, and choose explicit local limits sufficient for the job plus existing rolling usage. Edit only the needed local values. Each write still uses a complete preview and the host's normal confirmation policy; quota is not consent. Return to the preferred limits afterward; charges remain until their windows expire. If limits are lowered below recent usage, further charged writes remain blocked until usage ages out or the operator sets sufficient limits. No remote caller can raise these values.

These safeguards bound volume and rate, not intent. A harmful request below the caps can still fit within them, particularly for a small calendar. They do not cover changes made through other apps, prove a fresh human click, or resist a same-user attacker rewriting protected state. Advancing the trusted system clock can age the rolling windows. Preserve complete state/history across maintenance and backups as described below.

## Event scope, recovery and private state

Query windows are bounded to 93 days and 1000 events. IDs are opaque integration references; do not substitute titles/times for identity or guess a new ID when a provider changes one. Missing/ambiguous identity needs a fresh query. Writes address one event or an explicitly selected recurring occurrence (`scope: "this"`); whole-series creation/change and invitation/organizer mutations are unsupported. Nil-timezone all-day mutations, email/procedure alarms and location edits that cannot preserve an existing structured location are rejected.

New events default to `Europe/London`. Inputs require explicit offsets; UTC `Z` is accepted, while a local numeric offset must match the named timezone. Preserve existing nil timezone semantics; all-day ends are exclusive local-midnight boundaries. Availability is a snapshot, not a reservation. Provider concurrency and DST/recurrence edges are not exhaustively verified.

Normal writes have no Terminal approval or remote approval endpoint. A host denial never reaches the broker, and remembered host policy may suppress a fresh prompt. Calendar text is untrusted data. Audit covers native-received commits/configuration/recovery, not every host denial or other calendar client's edits; stateless preflight issuance is not logged.

After an uncertain commit/connection loss, **do not blindly retry or create a replacement preview**. Reconnect/restart if necessary, then call `get_change_status` with the original nonce. Consumed nonces remain consumed. Unknown outcomes block new writes until evidence-based local reconciliation; the transport never automatically retries or replaces a mutation.

Protect state, SQLite/associated files, exports and backups as sensitive before/after data (`0700` directories, `0600` files). Gateway/adapter logs omit credentials/request bodies. Keep raw HTTP payload tracing off in the tunnel client. `.gitignore` excludes runtime state, environment/credential files, keys, databases, logs and downloads; that is defense in depth, not a substitute for reviewing staged files before commit.

Before any stopped-state maintenance below—credential rotation, backup/restore, key rotation or reconciliation—run `./scripts/calendar-mcp service uninstall` if the optional service is installed. This preserves its private configuration and native history while preventing the monitor from restarting components during maintenance. Confirm the gateway, broker and managed tunnel have stopped. After maintenance, re-render only if configuration changed, then explicitly `service install` to resume login startup and monitoring. For a manual deployment, stop the tunnel and gateway yourself and restart them after maintenance.

To rotate the gateway credential while stopped, securely remove or archive only the old protected `gateway.token`, run `init`, then resume using the same native state through either service installation or the manual startup commands. The new token's local SHA-256 binding rotates native signing key/key ID/generation while preserving journal history. A running gateway retains its old token until stopped. Revoke/rotate the tunnel credential separately and securely update the approved local env file; service installation or a manual managed reconnect reloads its environment reference.

Retention is indefinite. There is no audit export/purge, automatic backup or history-merge CLI. Back up the entire protected native state only with the broker fully stopped, including policy, journal, immutable quota ledger and effective-time watermark. Never copy/overwrite a live SQLite database or manually delete audit/journal/quota rows. Never replace newer authoritative history with an older backup and resume writes: later nonces, intents and quota charges would be missing. Preserve or recover the newer immutable execution/quota history first; if it is unavailable, keep writes stopped for operator recovery. Key rotation cannot reconstruct missing history. For a valid stopped-state restore with authoritative history retained, invalidate old preview authentication before restarting:

```sh
"$PWD/build/Calendar MCP Helper.app/Contents/MacOS/CalendarHelper" \
  --rotate-keys --state-dir "$HOME/Library/Application Support/Private Calendar MCP/native-eventkit"
```

This is local state maintenance, not EventKit access. A backup cannot recover external writes made after it was taken; inspect possible outcomes and retain/recover their newer native history before resuming writes. Audit hash chains are tamper-evident relative to a trusted checkpoint, not tamper-proof against the same user rewriting history.

For an unresolved outcome, stop the gateway, inspect independent evidence, then use exceptional local attestation:

```sh
"$PWD/build/Calendar MCP Helper.app/Contents/MacOS/CalendarHelper" \
  --reconcile --state-dir "$HOME/Library/Application Support/Private Calendar MCP/native-eventkit" \
  --nonce ORIGINAL_PREVIEW_UUID --outcome applied \
  --evidence "Brief factual inspection evidence without sensitive details"
```

Use `not_applied` only when supported by evidence. A real TTY and typed nonce confirmation are required; this performs no Calendar mutation, records operator attestation and leaves the nonce consumed. It is not a normal write-consent surface. Avoid sensitive evidence in shell history/process arguments. The state lock excludes a running broker.

## Stop and remove

If the optional service is installed, run `./scripts/calendar-mcp service uninstall` first so its monitor cannot restart components during removal. Otherwise stop the managed tunnel with `runtimes stop <alias>` and stop the gateway gracefully (Ctrl-C for a foreground process). Remove the plugin/local MCP configuration and revoke the tunnel runtime credential if no longer needed. Retain or securely dispose of protected state/backups according to audit needs; deleting them loses history and changes installation identity. Revoke the helper's Calendar access in macOS Settings if it should no longer read calendars. Deleting source alone does not revoke OS or tunnel permissions.
