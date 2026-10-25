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

After server tool, schema or instruction changes, refresh and verify the private custom plugin before testing the changed capability:

1. Check that the active ChatGPT workspace and selected plugin use the intended server/tunnel association.
2. On the web, open the plugin's management/details page in app settings and scroll to the bottom: the user found **Refresh tool** there. Use it to pull current tools, descriptions and server instructions, and enable the intended tool toggles. This observed path is the web page; mobile app menus remain unverified. See the [custom MCP management workflow](https://developers.openai.com/api/docs/guides/custom-mcp-server#how-to-use).
3. After the combined future-feature rollout, verify all nineteen tools and `preflight_change.scope` accepting `this`, `series` and `future`. Confirm dedicated `commit_series_modify` / `commit_series_rollback`, `commit_future_modify` / `commit_future_rollback` and `commit_future_delete` / `commit_future_restore`. Legacy `commit_modify` and `commit_delete` intentionally remain occurrence-only. Future deletion additionally requires an exact cutoff; its recovery creates a separate new series with the signed limitations below. User-directed structural series edits and arbitrary historical/full-series deletion remain unsupported.
4. In a fresh chat, use `@` to select the correct plugin and explicitly request only `preflight_change` with `action: modify`, `scope: series`, an identified event and the exact intended default-field patch. Inspect expanded JSON tool details. This diagnostic prepares a preview only; do not call a commit tool.

If the plugin also has publishing controls, use **MCPs** → connected server → **Issues** → **Rescan**, wait for completion, then inspect **Issues found**, **Held update** and **Live definition**. New tools require approval; held changes leave existing tools' previously approved metadata live. See the [published-plugin update workflow](https://developers.openai.com/plugins/deploy/submission#update-to-your-mcp-server). These controls have not been verified in the user's private-plugin UI.

That earlier refresh is historical. The new combined rollout locally verified nineteen tools. One later version-5 future-modification call proves that tool was available and permitted for that call; independent inspection of the complete nineteen-tool host catalog and host/iPhone presentation remains pending. The final helper's actual resident full access is now independently verified from static metadata; this does not validate future-feature provider behavior or authorize unattended Calendar queries/writes.

After the user's web refresh, the owned runtime observed successful, complete discovery of all fifteen expected tool names, including both series commit tools, with no dispatch failures. The user later reported a fresh-chat series preview and a commit blocked by the then-unresolved journal entry; the full fifteen-tool UI has not been independently inspected. The earlier task's nine-tool catalog did not prove refresh failed. Local HTTP/stdio discovery and tunnel health alone do not establish host activation. See the [publication verification boundary](architecture.md#chatgpt-publication-verification). Tool refresh cannot reconcile journal outcomes. The separate human-attested reconciliation below cleared the former unresolved record; the deployed helper now uses the scoped conflict guard; it authorizes no Calendar mutation or retry.

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

The combined version-5/version-6 rollout is deployed and metadata-verified on 25 October. Installed signed SHA-256 `4fe2ce4560c1c5c0ea82ef9ace3091e19630c4fc9521d689fb1ce9ebc0a5f8dd` matches the staged signed artifact that passed all three synthetic LaunchServices checks; frozen raw SHA-256 is `f23d1b9cb4d8413fd05bf70529c99b797742636427f9fba891ffc929f0740b5b`. The single reviewed run advanced compatibility floor 3 to 5 with detail/marker encoding 2 and verified exact nineteen-tool/new-initialize metadata over protected HTTP and configured stdio. Exact baseline/final comparisons preserved all authoritative rows, ciphertext/keys, consumed nonces, quotas, audit/legacy history and identity/signing data: three executions (two applied, one reconciled), zero unresolved, two quota claims, four valid audit records and 132 identities. Protected configuration, policies and restart-budget histories were preserved. The same owned runtime profile/tunnel/environment reference was reconnected and monitoring resumed last.

The cutover resident reported `eventkit` / `not_determined`, raw 0. After the user first reported reenabling Full Access, one explicit active-user OS-authorization follow-up on the exact installed build exited successfully with `full_access:false`; resident and fresh same-build no-state diagnostics then reported `denied`, raw 2. Those observations are historical. The user subsequently reported no OS prompt and reenabling Full Access again. Read-only verification of the actual new resident, exact installed signed executable/inode and service-user ownership now confirms `eventkit` / `full_access`, raw 3. Both jobs are registered, gateway and exact owned tunnel/profile/command/environment reference are healthy, monitoring is current, and exact nineteen-tool/new-initialize metadata remains verified.

The monitor recorded automatic `restart_requested` at 18:49:31 UTC/UK time on 25 October, following an earlier `native_unavailable`/restart at 18:39:23. The timing does not prove the user's Settings action caused the recovery. Current stored/rolling gateway attempts are 2/2, tunnel 0; later normal recovery/pruning changed attempt history without resetting the budget. At that access verification, all authoritative native history matched the rollout proof, with three executions (two applied, one reconciled), zero unresolved, two quota claims, four valid audit records and 132 identities at floor 5/encoding 2. No Calendar query/write, fresh helper authorization probe/request, manual restart or rebuild ran in this verification. The rollout's zero-authorization count and the separate earlier single attended request remain distinct. Preserve the settled app. Full nineteen-tool host discovery/presentation and broader future-field/inverse/termination/copy-recovery validation remain pending; the single live version-5 milestone below does not establish resolution of the earlier version-4 host refusal.

The following paragraphs record the earlier scoped-guard deployment. Their full-access and fifteen-tool observations are historical.


The explicitly approved scoped-guard helper is installed, signed SHA-256 `7fd9594c51f8f130a942af21acc8d01e334adb0fe944cd034b145812388ce0e8`. Its code-only cutover preserved exact current history, configuration and budget histories. After the user reenabled Full Access in macOS Settings and accepted the OS-requested helper restart, the actual resident reports `eventkit` / `full_access`, raw 3. A connected-plugin listing returned twelve calendars on the replacement. Both jobs, gateway/tunnel and monitoring are healthy; current rolling gateway/tunnel restart counts are 2/0 after natural recovery. No manual permission refresh was needed. Three executions remain two applied and one reconciled, zero unresolved, two quota claims and a valid four-record audit chain. Exact immutable history and the original three-record audit prefix are preserved; the fourth record is a normal observation checkpoint. The code-only deployment made no Calendar call or permission request; the later read did not mutate Calendar data.

The previous security, series and alarm-order release was installed at `build/Calendar MCP Helper.app/Contents/MacOS/CalendarHelper`, signed executable SHA-256 `97d6a2fb537a769fda119cb50100597b99a1eac408f10acf34b2797c2f1baa01`. The frozen tested raw executable is `17898efb637eb7e13e31aac4b9358d0118c15405a04aaf69735a879795e8d37d`. New snapshots sort complete raw alarm objects deterministically, preserving all values and duplicates. Compatibility validates original fingerprints before allowing alarm order alone to differ; authenticated payloads and retained history remain unchanged.

The code-only rollout required no migration. Exact comparisons with its persisted pre-stop baseline preserved authoritative executions, encrypted details/keys, consumed nonces, audit/legacy history, quotas and security metadata, plus protected configuration, policies and monitor budgets. Storage compatibility floor remains 3 with version-2 detail/marker encoding. At that rollout, three executions were two `applied` and one `unknown`, with two quota claims and two audit records. The owned tunnel remained healthy without a restart. At that rollout, both Aqua jobs were active, monitoring and gateway/tunnel health were current, and rolling gateway/tunnel restart counts were 0/0. Protected Unix HTTP discovery returned the exact fifteen-tool schema.

**The prior alarm-fix app's OS grant and resident full access were verified.** After the user accepted its explicit prompt and the same-bundle service refresh completed, the actual resident reported `eventkit` / `full_access`, raw 3. A bounded live read/preflight check passed exact selected snapshots, raw alarm arrays and fingerprints for two recurring references. Both title-only version-4 previews identified the same complete first anchor, preserved all structural/unmasked fields, selected the dedicated series commit tool and signed the exact four recovery limitations. The probe did not normalize event or preview data. Authoritative table hashes/counts and identity counts were unchanged. No preview was saved and no commit, recovery preflight or reconciliation ran. The code-only rollout and later permission refresh themselves made no Calendar tool calls.

The former unknown is now `reconciled/not_applied` after the user explicitly authorized recording their best-knowledge assessment. At reconciliation verification, journal counts were three executions (two `applied`, one `reconciled`), zero unresolved, two retained quota claims and a valid three-record audit chain. The assistant entered the existing native CLI's private TTY confirmation on the user's behalf; encrypted evidence attributes the outcome to the user and retains the original unknown result. Audit records `local_operator_attestation` / `not_provided`, not independent historical proof or a fresh-human-click receipt. Exact checks preserved immutable payload/payload ciphertext/key/nonce, quotas and all other history, allowing only the selected result/state, one audit append and maintenance clocks. The reviewed lifecycle-lock/paused-monitor procedure kept the owned tunnel running and restored full-access gateway health and monitoring with budgets 0/0. It made no Calendar query, write or rename. The then-global guard was verified clear; the later scoped deployment preserved this history.

Source validation passed 100 native tests in 38.177 seconds, including nine alarm regressions. The frozen raw helper passed 110 Python tests in 4.703 seconds (107 passed, three explicit packaged LaunchServices skips); those three synthetic lifecycle checks separately passed against the exact signed staged app in 1.675 seconds with zero skips and unchanged executable hash. The bounded live checks establish read/preview stability for the selected references. Provider propagation, detached overrides/exclusions, alert delivery, recovery and refreshed ChatGPT/iPhone presentation remain unverified.

### Deployed scoped guard

The scoped helper from commit `bfb9d1e` is deployed after an explicitly approved code-only replacement, with no migration or automatic permission request. Its raw SHA-256 is `b44335204801027cd431a57dfa7f1d99b542661d738c9357b57815b5a2900c16`; installed signed SHA-256 is `7fd9594c51f8f130a942af21acc8d01e334adb0fe944cd034b145812388ce0e8`. Validation passed 121 native tests in 39.527 seconds, 110 Python tests in 5.463 seconds (107 passed, three expected packaged skips), and three staged synthetic lifecycle checks in 1.562 seconds with zero skips. After a neutral test-label cleanup, the single affected case passed in 0.117 seconds; native code and executable bytes were unchanged.

The [scoped conflict contract](architecture.md#scoped-conflict-guard-deployed) permits existing unrelated native groups only with frozen prior registry witnesses and disjoint affected series/recovery dependencies. New unwitnessed groups and same-calendar creation/restoration remain conservative; legacy history falls back to calendar/global blocking. Footprints are native-only future immutable marker metadata, not signed-preview fields. Storage floor 3, fifteen public tools, schemas, annotations, existing encrypted history, nonce consumption and quotas remain unchanged; no backfill or reconciliation is performed.

The earlier automatic-review rejection happened before execution and changed nothing; the subsequent explicit deployment approval authorized the exact reviewed cutover. It drained owned intake, captured stable current journal/audit/counter baselines, preserved all authoritative values and restarted monitoring last. Post-lock checks verified floor 3, exact fifteen-tool metadata, history, jobs, tunnel and budgets. Never auto-request Calendar access or restore older history. This native change does not bypass the separate OpenAI host safety refusal. The user approved changing only this calendar plugin to `ask_before_writes`, and host permission readback verified that mode. A subsequent series commit was still refused before native intent: its nonce remained `not_received`. No live Calendar write occurred, and the mode does not prove a fresh confirmation click.

### Historical deployment notes

The following records describe earlier storage/alert/recurrence releases. Their hashes, Calendar grants, thirteen-tool discovery and restart observations are superseded by the current security/series release above.

This dated operational note is separate from fresh installation. On 24 October 2026 the user explicitly approved database migrations without a database backup for the current and future feature/fix changes, supplementing standing feature/fix service-restart authorization. The reviewed storage-v2 migration and helper replacement then completed. An earlier automatic-review rejection happened before execution and was superseded by that explicit approval; it was not a migration failure.

The then-installed signed recurrence-capable helper executable at `build/Calendar MCP Helper.app/Contents/MacOS/CalendarHelper` has SHA-256 `a608e1bb46c8713eeb446fc6cf5e524ae6b51512ede91d8e3c40f7ce605a3ef9`. Source and rollout received Astra approval without findings. All 67 native tests passed in 13.913 seconds; the exact frozen raw helper (`1b471f10381f07759f545959eb56189d6da14328c67ba22df477def9c031b178`) passed 82 Python tests in 3.346 seconds (79 passed, three explicit packaged LaunchServices skips), plus an additional exact-frozen synthetic native watchdog test in 0.266 seconds. Synthetic validation does not establish real provider recurrence expansion, normalization, exclusions, identity behavior or consent rendering.

The recurrence upgrade was code-only, with no migration or backup. The reviewed rollout stopped the monitor, stopped the owned official managed runtime, then stopped the gateway; it atomically exchanged the app at the existing path and restarted the gateway. Exact thirteen-tool recurrence/alert/recovery HTTP metadata discovery passed before the owned official adapter was refreshed, and the monitor restarted last. Rollout verification preserved byte-identical metadata records and outcomes for all three executions (two `applied`, one `unknown`), both quota claims, the same valid two-record audit chain and native signing/identity/credential metadata. Protected configuration, environment reference, policies, plists and persisted monitor budgets were preserved. Static resident metadata stayed `eventkit` / `not_determined`, raw 0. No Calendar query, mutation, authorization prompt, retry or reconciliation was performed.

The earlier storage-v2 migration had verified cleanup and bound the eight-record legacy audit into its checkpoint; it backfilled two historical delete quota charges. The previous code-only multiple-alert release used signed helper SHA-256 `ca3e6f1e7bb1312f9dd7f6a558ee7455c6519ae1cce0e472b5c88388c3db55ac`. The following storage/alert rollout notes are historical and do not replace the recurrence-release status from that historical rollout.

The earlier reviewed storage-v2 rollout stopped the monitor before the gateway, migrated offline and atomically exchanged the app at the existing helper path. Its readiness parity check then stopped the jobs because the replacement reported Calendar `not_determined` instead of the old helper's `full_access`. The migration/helper replacement succeeded. The same gateway and monitor jobs were then bootstrapped forward with the upgraded helper, preserving configuration and monitor budgets. The gateway is reachable on **`127.0.0.1:18765`**, both owned jobs were successfully bootstrapped, and the existing official managed tunnel is healthy. No legacy helper was restarted against v2 state.

The subsequent multiple-alert upgrade performed no migration or backup. Its initial native replacement succeeded, but full discovery hit the local response parser's depth limit and both jobs were stopped. Reviewed forward repair applied the response-only depth-32 allowance (incoming requests remain limited to 20), restarted the owned gateway, and used official managed-runtime stop/connect with the unchanged protected profile/environment reference to respawn the stdio adapter. It verified backend/authorization parity (`eventkit`, `not_determined`, raw 0), exact thirteen-tool alert/recovery schema, healthy runtime ownership, unchanged three execution records (two applied, one unknown), two quota claims and the same valid two-record audit chain. Native identity/signing/credential metadata and protected service configuration/policies/token/monitor budgets were preserved; the monitor restarted last. Only MCP initialization and discovery were called, with zero Calendar tool calls, prompts, retries or reconciliation. Actual HTTP/stdio full-schema parsing is covered by the synthetic regression.

**At that earlier release, Calendar access awaited the user's local macOS grant.** The then-resident broker reported backend `eventkit`, authorization `not_determined`, raw 0. The user chose to grant access later; no unattended prompt was triggered. Permission absence is a nonrestartable condition for the monitor, not a reason for repeated restarts. At that time, granting access alone would leave the durable unknown blocking every fresh write until separate evidence-based reconciliation. Do not retry, infer an outcome or erase that history during permission repair.

Historical metadata-only direct HTTP initialization and `tools/list` returned the exact thirteen-tool recurrence/alert/recovery schema, including typed recurring creation, version-3 ordinary preview contracts, legacy versions and the four recovery operations, with zero `tools/call` requests. This verifies local capability discovery, not refreshed ChatGPT tool caching, a Calendar read or a production recovery write. Programmatic window-open acknowledgement was verified only with isolated synthetic state. The user explicitly chose to continue without a visual check; visual layout and click-through remain unverified.

Final recurrence-release service status reports installed/active, both owned jobs registered, a current monitor observation (`monitor_stale:false`) and a healthy tunnel. Gateway health is `permission`, matching the deferred raw-0 Calendar grant. Rolling service restart counts report zero gateway and zero tunnel; the previous tunnel attempt aged out naturally while persisted budget bytes were preserved. A separate smoke check using the exact configured Python `-m calendar_mcp stdio` command round-tripped MCP `2025-11-25` initialization and the complete thirteen-tool recurrence/alert/recovery schema with zero `tools/call` requests. These are local HTTP/stdio metadata checks; remote ChatGPT/iPhone discovery, presentation and real Calendar writes remain unverified.

Protected state remains `$HOME/Library/Application Support/Private Calendar MCP`, with active launch diagnostics under `service`. Port 8765's existing listener was untouched. The verified client is `build/tools/tunnel-client/v0.0.17/tunnel-client`, managed alias/profile is `calendar-studio`, and private generated profiles live under `.state/tunnel-profiles`. The runtime credential remains referenced through the approved ignored `.state/tunnel.env`; no key values or account/workspace/tunnel IDs belong in this repository. The generated stdio command uses its configured absolute Python interpreter with `-m calendar_mcp stdio --state-dir <configured-state> --port 18765` from the repository working directory.

```sh
./scripts/calendar-mcp service status
./scripts/calendar-mcp status --port 18765
./build/tools/tunnel-client/v0.0.17/tunnel-client runtimes status calendar-studio --json
```

Routine status checks do not request Calendar access. Do not start a duplicate gateway/runtime or signal a returned native PID. General stopped-state maintenance and configuration changes follow the maintenance procedure below. The reviewed migration used the existing lifecycle lock and stopped/reloaded the same jobs without uninstalling or resetting budgets; after a migration commits, repair forward with the upgraded helper rather than restore older state or restart the retained legacy code.

Historical validation before this replacement: natural periodic checks recovered the owned gateway and tunnel after separate controlled stops, and the older app reported full Calendar access. On 23 October the user verified a real read, test create and delete through ChatGPT and confirmed the create prompt. The delete prompt, complete confirmation fields, real modify and provider/recurrence/timezone edge cases remain unverified. The old five-record/zero-unresolved audit observation was later superseded by the eight-record/one-unknown pre-migration state; the historical v2 counts were preserved by the current compatibility-floor-3 rollout above. An actual reboot/login cycle and visible desktop notification delivery remain unverified. No personal event details or opaque IDs are recorded here.

## Bulk modify and delete protection

The upgraded Studio helper includes cumulative protections for destructive changes and the historical intent ledger described above. The prior scoped-guard replacement's full access/listing were verified historically; the final combined helper's actual resident full access is now independently verified, and no real quota-enforcement mutation was run. For compatibility with older helpers, tool wording remains conditional: if preflight has no `safety` feedback, cumulative protection is not confirmed. Source edits or policy files cannot upgrade an older binary. Preserve the settled app and verify its actual resident authorization; do not rebuild it merely for status checks.

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

The broker reloads the file during destructive preflight/commit, so a valid policy update needs no service restart. Preflight is advisory and does not adopt the file. A destructive commit durably adopts accepted policy revisions and audits their old/new values, hash and revision as local configuration, including if that commit is then rejected for insufficient quota. Initially, absence uses defaults; once a commit adopts an explicit file, removing it fails closed for new destructive calls rather than restoring defaults. Restore a complete valid protected file to repair that condition. Missing/invalid file errors use `write_safety_configuration`; exhausted limits use `write_safety_limit` with a safe retry time. These policy errors leave reads, status, creates and authenticated replays available; the scoped unresolved-intent guard independently blocks conflicting or insufficiently evidenced writes, with conservative calendar/global fallbacks for legacy history. Native database corruption/migration errors can still prevent startup. Raising or lowering limits never resets the durable usage ledger, even if the file is changed back. Native startup backfills existing durable modify/delete intents during upgrade. Restarting, credential rotation and reconciliation also preserve counts and the effective-time watermark used to clamp backward clock movement.

For a larger intended job, identify the exact changes, inspect the `safety` usage returned by a relevant `preflight_change`, and choose explicit local limits sufficient for the job plus existing rolling usage. Edit only the needed local values. Each write still uses a complete preview and the host's normal confirmation policy; quota is not consent. Return to the preferred limits afterward; charges remain until their windows expire. If limits are lowered below recent usage, further charged writes remain blocked until usage ages out or the operator sets sufficient limits. No remote caller can raise these values.

These safeguards bound volume and rate, not intent. A harmful request below the caps can still fit within them, particularly for a small calendar. They do not cover changes made through other apps, prove a fresh human click, or resist a same-user attacker rewriting protected state. Advancing the trusted system clock can age the rolling windows. Preserve complete state/history across maintenance and backups as described below.

## Individual and recurring events

The deployed recurrence release uses the existing preflight and commit tools. It adds typed series creation and signed standalone-copy recovery for a deleted recurring occurrence. Source/synthetic validation and metadata-only deployment verification are recorded in [architecture](architecture.md) and the [current deployment note](#current-studio-deployment). Real Calendar recurrence behavior and ChatGPT presentation remain unverified. Do not run the following examples against live calendars during unattended validation.

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

This feature is synthetically validated and deployed. It allows current-pattern title, notes, plain location and alerts through two dedicated write tools, with an exact minimum-floor-3 capability retained in the current floor-5/nineteen-tool deployment. Its version-4 contract does not enable structural series edits, future-only scope, series deletion or calendar-container deletion; future default fields have a separate version-5 contract below. Existing deployed recurrence behavior and its historical validation are recorded above. Do not run these examples against actual calendars during unattended tests.

The original series writer advanced the recovery metadata compatibility floor from version 2 to 3 while retaining version-2 detail/marker encoding and authoritative execution, replay, audit and quota history. A frozen older helper must reject the upgraded state. Existing version-2 helpers keep their prior thirteen-tool contracts; version-4 series discovery requires its exact minimum-floor-3 contract and a recognized actual floor >=3. After the upgrade, repair forward and preserve newer history rather than downgrading or restoring older state.

Identify the intended non-detached occurrence through normal scoped reads. Request the exact default-field change with `preflight_change`, for example:

```json
{"action":"modify","scope":"series","event_id":"<opaque-selected-occurrence-id>","fields":{"title":"Updated planning title","notes":"Updated default description","location":"Meeting room","alerts":[{"relative_minutes":-15}]}}
```

Only the supplied fields change. Omitted alerts preserve complete native alarms; `alerts:[]` clears them. Dates/times, timezone, all-day state, recurrence rules and calendar moves are rejected. Changing a structured location remains unsupported. The complete version-4 preview shows the originally selected occurrence, the first-anchor before/after fields, sorted `series.changed_fields` and signed limitations. Submit that unchanged `preview` through `commit_series_modify` under the host's confirmation policy. The ordinary `commit_modify` does not accept this broader preview.

The provider applies these defaults from the first occurrence of its current recurring pattern, including past and future occurrences within that pattern. Separate split segments are not merged. Detached overrides and exclusions remain provider-controlled; the integration does not verify every occurrence or guarantee identical propagation to every detached override. One series operation can affect an unbounded number of occurrences and consumes one modify intent. Other occurrence references may need a fresh query after provider identity changes.

Within retained detail availability (five days by default), select exactly one series source with `preflight_rollback`, for example `{"change_ids":["<source-change-id>"]}`. Review the complete inverse preview and route each step using its `commit_tool` field: version-4 series recovery uses `commit_series_rollback`; ordinary recovery uses `commit_rollback`. The hint is not authority, and each tool checks its exact native-authenticated contract. Series inverse reapplies only the masked prior defaults and any masked raw alarms to the same current pattern. It does not reconstruct overrides, exclusions, previous structure, identities or earlier split segments.

Mixed series/occurrence or multiple-source series undo is rejected. Any later integration execution intent in the same calendar blocks series inverse; ambiguous legacy independence also blocks it. Ordinary occurrence recovery cannot cross a newer series-default edit in that calendar. These conservative guards remain after detailed data expires. Any unknown outcome still blocks fresh writes and requires evidence-based local reconciliation. After uncertain transport, inspect the original nonce through `get_change_status` without retrying or preparing a replacement attempt.

The original security/series source validation passed 91 native tests and the frozen helper's full 110-test Python suite (107 passed; three explicit packaged LaunchServices tests skipped). Those three lifecycle tests separately passed against the staged signed app with zero skips and an unchanged executable hash. The synthetic version-4 lifecycle and complete fifteen-tool protected Unix HTTP/stdio discovery both executed successfully.

The [architecture contract](architecture.md#current-pattern-default-field-modification) records the exact capability, version-4 payload and lineage design. Synthetic contract/discovery tests do not establish real provider propagation, first-anchor identity changes, exception behavior, alert delivery or host presentation; those remain separate scoped live validation tasks.

## Future occurrence default fields

This separate version-5 feature is implemented, synthetically validated and deployed in the combined nineteen-tool floor-5 helper. Metadata-only rollout is verified; its current actual resident full access is verified. Do not run these examples against actual calendars during unattended tests. Cutoff termination is a separate version-6 contract below; the version-5 tools reject it.

Live milestone on 25 October: one user-initiated ChatGPT title-only version-5 future modification was verified applied through read-only inspection of its retained journal and native-observed result. The exact title mask, still-future signed boundary, structural/unmasked fields, tail recurrence/complete alarms/URL/unrelated metadata passed bounded checks; the earlier-anchor witness passed preservation guards, including the allowed provider termination change. One intent, one quota charge and one applied audit were recorded without a write-unknown outcome. Audit provenance is `chatgpt_host_policy` / `not_provided`; fresh-human-click evidence and exhaustive past/detached preservation are not established. This proves future-tool availability/permission for that call, not all nineteen host tools or resolution of the earlier version-4 refusal. Agents made no Calendar/provider/status call, authorization request or restart for this verification. Version-5 inverse and version-6 termination/copy recovery remain live-unverified.

Query the exact intended future non-detached occurrence and use its opaque reference. The selected occurrence is included. Request a nonempty subset of title, notes, plain location and alerts:

```json
{"action":"modify","scope":"future","event_id":"<exact-future-occurrence-id>","fields":{"title":"Updated future planning title","alerts":[{"relative_minutes":-15}]}}
```

The selected start must be strictly later than native now, and its occurrence identity must equal that start. Elapsed/ongoing events, detached or ambiguous references, no-op requests, count-ended patterns and multiple recurrence rules are rejected before intent. The first subset accepts exactly one supported unbounded or date-ended rule. Dates/times, timezone, all-day, recurrence and calendar moves cannot be changed. Omitted alerts preserve complete alarms; `[]` clears them. Existing writable-calendar, invitation, structured-location and unsupported-alarm guards apply to the selected occurrence and original first anchor.

The complete version-5 preview signs the selected full `before`, selected-rooted full `after`, `future.boundary`, the complete original `future.first_anchor`, sorted `future.changed_fields`, and four exact `future_default_fields` limitations. Expiry is capped at the selected start. Pass the returned complete unchanged preview through `commit_future_modify` under the host confirmation policy; legacy and version-4 commits reject it. The broker checks native time before claim and the provider checks it again immediately before its one `.futureEvents` save. A clock crossing after durable intent is conservatively unknown; no automatic retry or compensation occurs.

EventKit may split the provider pattern and change identities and recurrence end metadata. Earlier occurrence fields and times are outside the request; earlier split segments are not merged. Native verification checks the directly saved tail boundary and, when applicable, the exact earlier first-anchor witness. It does not enumerate every past occurrence or guarantee detached-override propagation. Only the selected boundary reference can be rebound to the verified direct-save identity; other stale sibling references require a new query.

To recover, select exactly one original retained applied future change alone through `preflight_rollback`. Its original boundary must still be strictly future, the current tail and first anchor must exactly match the retained verified segment, and later possibly related intents block recovery. Submit the exact returned step through its `commit_tool:commit_future_rollback`. The inverse restores only masked prior defaults and exact retained masked alarms to that same future segment. It does not merge segments or reconstruct recurrence topology, overrides, exclusions or identities. Recovery can become unavailable before the normal detail-retention expiry. Mixed selections, recursive inverse recovery and choosing a later boundary automatically are unsupported.

Every future intent consumes one modify charge and can affect an unbounded number of occurrences. Its native conflict footprint is deliberately incomplete at the trusted calendar boundary, so an unknown future outcome blocks every same-calendar mutation; independent other calendars remain subject to existing evidence checks. Applied or expired future history also remains a recognizable series boundary for conservative recovery crossing checks. Original payloads and nonces remain immutable and replay returns the stored outcome without another save or charge.

The version-5-only writer advances only compatibility metadata from floor 3 to 4, keeps detail/marker encoding 2 and preserves all existing authoritative rows, ciphertext/keys, consumed nonces, quota/audit/legacy/identity/signing history. Repair forward after startup migration commits. The combined source accepts recovery floors 2 through 5, retains exact old recurrence/series/future capability objects as minimum contracts, and exposes the version-5 tools at recognized floor >=4 when every required capability matches; a verified version-6 helper additionally exposes nineteen tools. Older helpers retain their supported nine/thirteen/fifteen-tool sets. Build/startup/capability probing and metadata verification request no Calendar access.

Final source validation passed all 139 native tests in 44.040 seconds, including 18 focused future tests (5.614 seconds). The final frozen raw helper SHA-256 `4b7895c799f0be55c6b4052df5e4bfa522e3c396a551ddec77c68c273acaf347` ran 116 Python tests in 5.858 seconds: 113 passed and three explicit packaged LaunchServices lifecycle tests were skipped until a staged signed app is available. This includes the actual synthetic version-5 apply/inverse/replay lifecycle and full seventeen-tool protected HTTP/stdio discovery. No actual Calendar data, authorization or production services were involved.

The [exact architecture contract](architecture.md#future-default-field-modification) distinguishes source behavior from deployed behavior. Synthetic verification does not establish iCloud propagation, complete past/exception preservation or ChatGPT/iPhone presentation. The user-approved/readback-verified `ask_before_writes` host mode does not bypass the separate OpenAI safety refusal or prove a fresh human click.

## Stop a pattern from a cutoff and create an independent recovery copy

This separately authorized version-6 feature is implemented, synthetically validated and deployed. The combined nineteen-tool helper is metadata-verified at floor 5; its actual resident full access is verified while live feature validation remains pending. The separately committed version-5-only artifact was validated at floor 4. No actual Calendar data or production services are part of unattended validation.

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

The v6 writer advances compatibility floor 4 to 5 while preserving encoding 2 and every historical row/cipher/key/nonce/audit/quota/identity/signing value. Frozen floor-4 helpers refuse floor 5. Legacy series/future capability objects retain minimum versions 3/4, recovery accepts recognized floors 2 through 5, and exact v6 capability verification exposes nineteen tools. Repair forward after migration commits. `commit_future_delete` truthfully advertises destructive write semantics; `commit_future_restore` advertises creation semantics like `commit_create`, because it creates a separate new series without modifying the prefix. These annotations describe actions and do not bypass host safeguards.

Final source validation passed all 158 native tests in 53.063 seconds, including 20 focused tests in 7.451 seconds. The final frozen raw helper SHA-256 `f23d1b9cb4d8413fd05bf70529c99b797742636427f9fba891ffc929f0740b5b` ran 123 Python tests in 6.280 seconds: 120 passed and three explicit packaged LaunchServices checks were skipped. Those exact three checks separately passed in 1.430 seconds with zero skips against the private staged signed app SHA-256 `4fe2ce4560c1c5c0ea82ef9ace3091e19630c4fc9521d689fb1ce9ebc0a5f8dd`; its hash remained unchanged. Actual synthetic v6 termination/independent-copy/replay/source-ownership and legacy v5/occurrence recovery passed, alongside full nineteen-tool protected HTTP/stdio discovery. No installed bundle, production service or actual Calendar data was involved.

Source/synthetic verification and the [exact architecture contract](architecture.md#cutoff-termination-and-independent-tail-copy) do not establish live iCloud normalization, complete detached/topology behavior or ChatGPT/iPhone presentation. Those remain separately scoped live validation tasks. The separate OpenAI safety gate remains unchanged.

## Multiple event alerts

The multiple-alert source change uses the existing `preflight_change` and matching commit tools; it adds no tool or approval step. All 56 native tests passed. The exact final frozen raw helper passed the full 75-test Python suite in 3.124 seconds: 72 passed and three explicit packaged LaunchServices tests skipped. Coverage includes synthetic creation, addition/edit/removal/clearing, omitted-field preservation, tamper rejection, replay and exact raw-alarm recovery after modification/deletion, alongside existing HTTP/stdio/recovery integration. The feature is deployed on the Studio with metadata-only verification. Actual Calendar alarm delivery, provider-specific behavior and refreshed ChatGPT presentation remain unverified. The later installed alarm-fix app's grant and bounded read/preview proof are recorded above.

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

This recovery feature is implemented, reviewed, synthetically tested and **deployed on the Studio with metadata-only verification**. The combined rollout is metadata-verified; the final helper's actual resident full access is independently verified, and production recovery writes remain unverified. Earlier replacement access/listing records are historical. The gateway probes the actual resident helper once with internal metadata-only `recovery_capabilities`. Only the exact supported storage/version/capability response enables the four ordinary recovery tools; dedicated series/future tools additionally require their exact independent capabilities and minimum recognized storage floors 3/4/5. An older helper keeps the original nine tools and rejects recovery dispatch as unavailable. A gateway/source restart alone cannot enable recovery, retention, or encrypted native storage on an older helper.

Historical security/series deployment: the approved offline upgrade established compatibility floor 3 while preserving version-2 encrypted detail/marker encoding and authoritative history. Protected Unix/configured-stdio discovery returned fifteen tools; both jobs were active, tunnel health and monitoring were current. The prior alarm-fix resident reported full access, and scoped strict read-to-v4-preview matching passed for two references with a common complete first anchor. The later scoped-guard replacement's full access and calendar listing were separately verified then. Those historical grants/read checks made no live series write or recovery preflight and do not establish the final combined helper's access or live behavior. The human-attested reconciliation and scoped conservative conflict guards remain preserved in the combined deployment above.

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
./scripts/calendar-mcp changes list --port 18765 --limit 50
./scripts/calendar-mcp changes list --port 18765 --cursor '<next_cursor>'
./scripts/calendar-mcp changes show '<change_id>' --port 18765
./scripts/calendar-mcp changes open --port 18765
```

Add `--state-dir <gateway-state>` when using a nondefault state. `changes open` verifies recovery discovery and sends only `{"op":"open_changes"}` to the existing broker's protected deterministic local socket; the socket lives under `<protected-Darwin-user-temp>/cmui-<first20-SHA256-canonical-native-path>/s`, inside a strict owned `0700` directory with an owned `0600` socket and native peer-UID validation. This fixed derivation supports long state paths. The command does not start another state owner, submit a preview or approve anything. The standalone native window lists, filters and shows history, supports selected changes or **Select all matching**, traverses all snapshot pages, and displays exact batches for review. Its native Apply control captures the displayed preview and executes within the broker; no Terminal approval, remote approval API or caller-provided approval boolean is involved. Local actions use `approval_source: local_native_ui` and `approval_evidence: native_control_activated`, distinct from MCP `chatgpt_host_policy` / `not_provided`. Neither path claims a backend-verifiable fresh ChatGPT human click. The gateway and broker must already be running in the logged-in desktop session; use `--backend synthetic` only for isolated fixtures.

Storage-v2 migration is native, fail closed and transactional. It verifies legacy audit integrity, encrypts legacy details, preserves all consumed nonces, unresolved intents and quota claims, and starts the minimal v2 audit chain with the legacy tail/count, conversion checkpoint and integrity-bound legacy manifest. Retained event-bearing legacy audit bodies are encrypted under the same expiring execution keys. Original capture times govern migrated expiry. Migration does not reconcile a pre-existing unknown; such outcomes retain scoped conflict protection with conservative calendar/global fallbacks until resolved. Complete stopped-state backups and their keys remain sensitive and authoritative history must never be replaced by an older copy. Migration/expiry does not repair a missing or stale backup history. Once a v2 checkpoint commits, do not restart a legacy helper or restore an older database to bypass cleanup; keep jobs stopped and repair forward with the upgraded helper. A persisted cleanup-pending flag and native v2 write constraints fail closed across interrupted cleanup or attempted legacy writes.

Final source validation ran 69 Python tests in 2.784 seconds (66 passed; three explicit LaunchServices checks skipped), including synthetic native recovery, HTTP/stdio/quota paths and the actual native-created endpoint on long temporary state paths. All 48 native tests passed for migration, expiry, unresolved holds, restoration and recovery guards. The exact final native artifact also passed 13 focused CLI/native checks in 1.376 seconds after the final retention/UI changes. Programmatic native window-open acknowledgement was verified separately. The user explicitly chose to continue without a visual check; visual layout and click-through remain unverified. These automated checks used isolated synthetic state and did not access real Calendar data. A subsequent explicitly authorized rollout deployed and metadata-verified the helper as recorded above. Full interactive Apply and production Calendar recovery remain unverified.

## Floating all-day metadata preservation: source fix

This preserve-only fix is implemented and Astra-reviewed in source, synthetically validated and not deployed. The settled installed signed4fe helper remains unchanged at floor 5/nineteen tools. No actual Calendar query/write, authorization, reconciliation or service restart was part of validation.

Existing nil-timezone all-day records can use supported title, notes, plain location and complete-alert edits only when start, end, timezone and all-day state remain exactly the observed raw values. Ordinary occurrence edits, current-pattern/version-4 and future/version-5 default edits, and their supported inverse paths use that same preservation rule. Metadata edits do not infer midnight, substitute a display timezone, normalize endpoints or rewrite unrelated raw temporal state. Existing structural, invitation, alarm, location, stale-state, quota and journal guards remain authoritative.

Creation, deletion/copy recovery, date/time or timezone edits, timed/all-day conversion and version-6 termination remain unsupported for nil-timezone all-day records in this fix. A separate civil-date contract is required to interpret or correct dates. An earlier unknown all-day creation remains immutable and unresolved; this fix does not retry, reinterpret or reconcile it. It does not solve provider end-representation normalization during creation.

All 163 native tests passed in 54.335 seconds, including five focused tests in 1.166 seconds. Frozen raw SHA-256 `4033b7c86e1aca40ad660de46b5ee5439409d6d1e9b935dd933015074e05d6d3` ran the existing 123-test Python suite in 6.283 seconds: 120 passed and three explicit packaged LaunchServices tests were skipped. The fixtures preserve exact non-midnight raw endpoints, nil timezone, unrelated metadata/alarms, replay and inverse behavior, and reject unsupported structural requests before intent. Live provider behavior and deployment remain unverified.

## Event scope, recovery and private state

Query windows are bounded to 93 days and 1000 events. IDs are opaque integration references; do not substitute titles/times for identity or guess a new ID when a provider changes one. Missing/ambiguous identity needs a fresh query. The recurrence release supports new series creation (`scope:"series"` plus a typed recurrence rule); modification/deletion addresses one identified event or occurrence (`scope:"this"`). The installed helper supports the restricted version-5 future default-field subset and separate version-6 cutoff-termination contract documented above. User-directed structural series edits, arbitrary historical/full-series deletion, recurrence-rule changes and invitation/organizer mutations remain unsupported. Restricted cutoff termination is the separate version-6 contract above. Current-pattern title, notes, plain location and alerts use the dedicated version-4 tools described above. A new recurring/detached occurrence deletion requires version-3 signed standalone-copy recovery disclosure; older contracts remain blocked. See [individual and recurring events](#individual-and-recurring-events) for source/deployment distinctions and examples. The installed helper still rejects nil-timezone all-day mutations; the undeployed preserve-only source fix above narrowly supports metadata/alerts with exact raw temporal preservation. Email/procedure alarms and location edits that cannot preserve an existing structured location remain rejected.

New events default to `Europe/London`. Inputs require explicit offsets; UTC `Z` is accepted, while a local numeric offset must match the named timezone. Preserve existing nil timezone semantics. All-day write inputs use exclusive local-midnight ends; raw EventKit snapshot endpoints are preserved as observed and may use a different provider representation. Availability is a snapshot, not a reservation. Provider concurrency and DST/recurrence edges are not exhaustively verified.

Normal writes have no Terminal approval or remote approval endpoint. A host denial never reaches the broker, and remembered host policy may suppress a fresh prompt. Calendar text is untrusted data. Audit covers native-received commits/configuration/recovery, not every host denial or other calendar client's edits; stateless preflight issuance is not logged.

After an uncertain commit/connection loss, **do not blindly retry or create a replacement preview**. Reconnect/restart if necessary, then call `get_change_status` with the original nonce. Consumed nonces remain consumed. Unknown outcomes retain scoped conflict protection until evidence-based local reconciliation, including conservative calendar/global fallbacks when evidence is incomplete; the transport never automatically retries or replaces a mutation.

Deployed transport hardening rejects malformed Unicode strings/keys and nonfinite numbers before native submission. A native `invalid_arguments` response explicitly states that no request was submitted and leaves a healthy broker available; it does not attest any previous uncertain outcome. This change is deployed; live Calendar validation remains separate.

The deployed stdio adapter also rejects invalid request IDs safely, handles malformed initialize parameters and contains invalid gateway result serialization while allowing subsequent framed requests. If a response fails after possible write submission, its error retains the no-retry guidance above; a continuing connection does not establish the write outcome. This adapter change is deployed.

Deployed local-window IPC uses Darwin's protected per-user temporary base and ignores `TMPDIR` and public legacy endpoint preclaims. An unavailable optional native window reports `local_ui:false` while the broker and four remote history/recovery tools remain usable. These changes are deployed; remote recovery still uses exact previews, native journal checks and the host consent policy.

Native accounting hardening is deployed. New rejected/replayed commit observations use exact durable counters in fixed operation/reason/origin buckets, with at most one dirty cumulative hash-chain checkpoint per persisted effective hour. Quota denials are counted once; accepted policy adoption and quota charges remain separately audited. Replays return the same recorded outcome without a new provider write or charge. Counters expose total/checkpointed/pending values through internal metadata-only `commit_observation_status`; pending rows are mutable operational accounting, not per-attempt chain evidence or proof of a fresh click. Restart/backward clock movement cannot reset counts or accelerate checkpoints, and counter corruption/exhaustion fails closed. The additive upgrade preserves all existing audit/legacy rows, execution payloads/outcomes, consumed nonces, unresolved evidence, detail keys and quota claims.

The deployed retention implementation indexes expiry candidates and unresolved executions. Each operation still persists the retention high-water mark before the indexed due check; exact expiry, ancestor holds and no-resurrection semantics are unchanged. Normal checks avoid reconstructing resolved history; due cleanup may still process many expired records. The accounting/retention change passed its original 76 native tests and five actual-native synthetic HTTP/stdio tests, including existing-v2 preservation; the original security/series integrated release passed all 91 native and 110 Python tests as recorded above. Those checks used isolated synthetic state; the reviewed release was subsequently deployed with preserved history and metadata-only verification, without Calendar data access.

Protect state, SQLite/associated files, exports and backups as sensitive before/after data (`0700` directories, `0600` files). Gateway/adapter logs omit credentials/request bodies. Keep raw HTTP payload tracing off in the tunnel client. `.gitignore` excludes runtime state, environment/credential files, keys, databases, logs and downloads; that is defense in depth, not a substitute for reviewing staged files before commit.

For ordinary stopped-state maintenance below—credential rotation, backup/restore, key rotation or reconciliation—run `./scripts/calendar-mcp service uninstall` if the optional service is installed. This preserves its private configuration and native history while preventing the monitor from restarting components during maintenance. Confirm the gateway, broker and managed tunnel have stopped. After maintenance, re-render only if configuration changed, then explicitly `service install` to resume login startup and monitoring. For a manual deployment, stop the tunnel and gateway yourself and restart them after maintenance. The one recorded attestation used a separately reviewed exception: hold the existing lifecycle lock, pause the owned monitor, stop the owned gateway, verify native unlock, then restore the same full-access gateway and monitor last while preserving configuration/budgets and leaving the healthy tunnel running. That exception is not a general instruction to bypass stopped-state safety checks.

To rotate the gateway credential while stopped, securely remove or archive only the old protected `gateway.token`, run `init`, then resume using the same native state through either service installation or the manual startup commands. The new token's local SHA-256 binding rotates native signing key/key ID/generation while preserving journal history. A running gateway retains its old token until stopped. Revoke/rotate the tunnel credential separately and securely update the approved local env file; service installation or a manual managed reconnect reloads its environment reference.

The deployed helper uses compatibility floor 5 and version-2 encrypted detail encoding to implement the bounded detail retention described above while preserving minimal replay/audit/quota history. Its pre-migration legacy format retained details indefinitely. There is no audit export/purge, automatic backup or history-merge CLI. Back up the entire protected native state only with the broker fully stopped, including both policies, encrypted details and their keys, journal, immutable quota ledger and effective-time watermark. Never copy/overwrite a live SQLite database or manually delete audit/journal/quota rows. Never replace newer authoritative history with an older backup and resume writes: later nonces, intents and quota charges would be missing. Preserve or recover the newer immutable execution/quota history first; if it is unavailable, keep writes stopped for operator recovery. Key rotation cannot reconstruct missing history. For a valid stopped-state restore with authoritative history retained, invalidate old preview authentication before restarting:

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
