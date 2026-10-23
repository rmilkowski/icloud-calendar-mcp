# Installation and operation

This is the authoritative installation guide. Use the fresh-install steps on a new Mac; use [Current Studio deployment](#current-studio-deployment) for the existing installation. **Do not rebuild an already authorized app just to follow this guide:** an ad-hoc signature change can reset its Calendar grant.

## Installation checklist

1. Configure the desired accounts in macOS Calendar, then install the prerequisites.
2. Build/sign the helper and run synthetic tests before requesting Calendar access.
3. Explicitly grant the bundled app full Calendar access on the Mac that will run it.
4. Initialize private state, start the local gateway and verify native authorization with `status`.
5. Download/verify the current official tunnel client, configure a private tunnel and restricted runtime credential, then start a managed runtime.
6. Add the tunnel in ChatGPT Plugins and verify a scoped read; separately verify each intended write path and its host confirmation.

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

No gateway login/reboot service is installed. For a manual restart, stop the existing gateway gracefully, rerun the same `serve` command with the same state/port/bundle, then check status. A background installation must be managed separately; avoid duplicate gateways for one native state.

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

Do not overwrite an existing credential unnecessarily. The file is ignored by Git. Source **only this trusted, user-approved file**, with tracing disabled; never `cat` it or print the environment. The managed profile stores `env:CONTROL_PLANE_API_KEY`, not a plaintext key.

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

This dated operational note is separate from fresh installation. On 23 October 2026 the gateway is running in the background on **`127.0.0.1:18765`**, using `$HOME/Library/Application Support/Private Calendar MCP` and protected `gateway.log` there. Port 8765 was occupied and its listener was left untouched. No gateway automatic startup service is installed; do not rebuild the settled authorized app merely to inspect it.

The verified client is `build/tools/tunnel-client/v0.0.17/tunnel-client`, managed alias/profile is `calendar-studio`, and private generated profiles live under `.state/tunnel-profiles`. The runtime credential is referenced through the approved ignored `.state/tunnel.env`; no key values or account/workspace/tunnel IDs belong in this repository. The active stdio command is `scripts/calendar-mcp stdio --port 18765`.

```sh
./scripts/calendar-mcp status --port 18765
./build/tools/tunnel-client/v0.0.17/tunnel-client runtimes status calendar-studio --json
```

To stop the tunnel, use `./build/tools/tunnel-client/v0.0.17/tunnel-client runtimes stop calendar-studio`. For a managed reconnect, repeat the secure environment-loading/connect block above using alias/profile `calendar-studio`, the existing private tunnel ID, the same profile directory, and **`calendar_port=18765`**. Restart the gateway first if needed with `--backend eventkit --port 18765`, the same private state and the settled helper bundle. Never use the returned native PID as a stop instruction.

Observed validation: 16 native tests and 24 Python tests passed, including synthetic HTTP/stdio replay, credential rotation and LaunchServices lifecycle/death tests. The production resident broker reported `full_access`/raw 3; a shutdown probe confirmed native exit. Managed tunnel status was healthy/ready, authenticated polling and MCP initialization succeeded. Earlier current-epoch `tools/list` was not observed, so no cached full tool-list observation is claimed; transport counters also included a dispatcher failure rather than universal success.

The user verified an end-to-end real read on ChatGPT iPhone, then a test create and delete. Read-only journal/audit checks found create and delete both `applied`, matching `write_intent` → `write_applied` records, a valid five-record chain and no unresolved executions. Native completion follows EventKit read-back/deletion verification. The user confirmed a ChatGPT prompt before **create**; the delete prompt and complete UI fields were not independently verified. No event details, exact personal times or opaque IDs are recorded here. Real modify and provider/recurrence/timezone edge cases remain unverified. Backend audit does not provide cryptographic proof of fresh human approval.

## Event scope, recovery and private state

Query windows are bounded to 93 days and 1000 events. IDs are opaque integration references; do not substitute titles/times for identity or guess a new ID when a provider changes one. Missing/ambiguous identity needs a fresh query. Writes address one event or an explicitly selected recurring occurrence (`scope: "this"`); whole-series creation/change and invitation/organizer mutations are unsupported. Nil-timezone all-day mutations, email/procedure alarms and location edits that cannot preserve an existing structured location are rejected.

New events default to `Europe/London`. Inputs require explicit offsets; UTC `Z` is accepted, while a local numeric offset must match the named timezone. Preserve existing nil timezone semantics; all-day ends are exclusive local-midnight boundaries. Availability is a snapshot, not a reservation. Provider concurrency and DST/recurrence edges are not exhaustively verified.

Normal writes have no Terminal approval or remote approval endpoint. A host denial never reaches the broker, and remembered host policy may suppress a fresh prompt. Calendar text is untrusted data. Audit covers native-received commits/configuration/recovery, not every host denial or other calendar client's edits; stateless preflight issuance is not logged.

After an uncertain commit/connection loss, **do not blindly retry or create a replacement preview**. Reconnect/restart if necessary, then call `get_change_status` with the original nonce. Consumed nonces remain consumed. Unknown outcomes block new writes until evidence-based local reconciliation; the transport never automatically retries or replaces a mutation.

Protect state, SQLite/associated files, exports and backups as sensitive before/after data (`0700` directories, `0600` files). Gateway/adapter logs omit credentials/request bodies. Keep raw HTTP payload tracing off in the tunnel client. `.gitignore` excludes runtime state, environment/credential files, keys, databases, logs and downloads; that is defense in depth, not a substitute for reviewing staged files before commit.

To rotate the gateway credential, stop the gateway/adapters/tunnel, securely remove or archive only the old protected `gateway.token`, run `init`, and restart with the same native state. The new token's local SHA-256 binding rotates native signing key/key ID/generation while preserving journal history. A running gateway retains its old token until stopped. Revoke/rotate the tunnel credential separately and securely update the approved local env file, then managed-reconnect with its environment reference.

Retention is indefinite. There is no audit export/purge or automatic backup CLI. Back up the entire protected native state only with the broker fully stopped; never copy/overwrite a live SQLite database or manually delete audit/journal rows. After restoring a stopped backup, invalidate old preview authentication before restarting:

```sh
"$PWD/build/Calendar MCP Helper.app/Contents/MacOS/CalendarHelper" \
  --rotate-keys --state-dir "$HOME/Library/Application Support/Private Calendar MCP/native-eventkit"
```

This is local state maintenance, not EventKit access. Restoring an older backup cannot recover omitted external writes; inspect possible outcomes before resuming. Audit hash chains are tamper-evident relative to a trusted checkpoint, not tamper-proof against the same user rewriting history.

For an unresolved outcome, stop the gateway, inspect independent evidence, then use exceptional local attestation:

```sh
"$PWD/build/Calendar MCP Helper.app/Contents/MacOS/CalendarHelper" \
  --reconcile --state-dir "$HOME/Library/Application Support/Private Calendar MCP/native-eventkit" \
  --nonce ORIGINAL_PREVIEW_UUID --outcome applied \
  --evidence "Brief factual inspection evidence without sensitive details"
```

Use `not_applied` only when supported by evidence. A real TTY and typed nonce confirmation are required; this performs no Calendar mutation, records operator attestation and leaves the nonce consumed. It is not a normal write-consent surface. Avoid sensitive evidence in shell history/process arguments. The state lock excludes a running broker.

## Stop and remove

Stop the managed tunnel with `runtimes stop <alias>` and stop the gateway gracefully (Ctrl-C for a foreground process). Remove the plugin/local MCP configuration and revoke the tunnel runtime credential if no longer needed. No gateway startup service is installed by these scripts. Retain or securely dispose of protected state/backups according to audit needs; deleting them loses history and changes installation identity. Revoke the helper's Calendar access in macOS Settings if it should no longer read calendars. Deleting source alone does not revoke OS or tunnel permissions.
