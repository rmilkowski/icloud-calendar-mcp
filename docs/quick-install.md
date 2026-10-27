# Quick install

This path is for a **fresh installation on the Mac that will run Calendar MCP**. For an existing installation, read [upgrade an existing installation](setup.md#upgrade-an-existing-installation) and the [full operating guide](setup.md): preserve its settled app, grant, state, tunnel and service configuration. Do not rebuild it or repeat permission requests just to follow this page.

## 1. Prepare and build

Use macOS 14+, Swift 6/Xcode Command Line Tools and Python 3.11+ with timezone data. Configure the intended accounts in macOS Calendar first. From the downloaded repository:

```sh
cd "/absolute/path/to/iCloud Calendar MCP"
./scripts/test-native
./scripts/build-helper.sh
python3 -m unittest discover -s Tests -v
```

This creates `build/Calendar MCP Helper.app` with a local ad-hoc signature. For an existing stable signing identity, set `CALENDAR_SIGNING_IDENTITY` when first building. Rebuilds can reset Calendar permission. Tests are synthetic and grant no Calendar access; see [build options](setup.md#2-build-sign-and-test-a-fresh-installation) if SwiftPM sandboxing is unavailable.

## 2. Grant the exact app Calendar access

This is an attended local OS step, separate from permission to change events. Skip it if the settled app already has Full Access. On the execution Mac's logged-in desktop:

```sh
/usr/bin/open -n -W -g "$PWD/build/Calendar MCP Helper.app" --args --authorize
```

Respond to macOS locally; enable the app in **System Settings → Privacy & Security → Calendars** if needed. Use LaunchServices for the exact `.app`, not the executable directly. Do not repeat requests automatically or reset TCC. The running broker's status in the next step is the access check; see [permission troubleshooting](setup.md#3-grant-calendar-permission-to-the-app).

## 3. Run the gateway

Use port **8765** consistently throughout this example. From the repository:

```sh
./scripts/calendar-mcp init
./scripts/calendar-mcp serve \
  --helper "$PWD/build/Calendar MCP Helper.app/Contents/MacOS/CalendarHelper" \
  --backend eventkit --port 8765
```

Keep it running. In another Terminal, from the same repository:

```sh
./scripts/calendar-mcp status --port 8765
```

Expect a reachable gateway and native `eventkit / full_access`, raw 3. Status reads metadata only. Default private state is `~/Library/Application Support/Private Calendar MCP`; `init` creates a protected gateway token without displaying it. If choosing `--state-dir`, pass the same absolute directory to every gateway, status, stdio and service command. See [gateway details](setup.md#4-start-the-gateway-and-check-status).

## 4. Connect a private tunnel

[Download and verify the official tunnel client](setup.md#5-install-the-official-private-tunnel-client), keeping its bundled resources together. Select/create the intended private tunnel and restricted runtime credential as described in [credential setup](setup.md#6-configure-credentials-and-a-managed-private-tunnel). Do not use an admin key for the runtime.

Prepare the private credential destination:

```sh
(umask 077; mkdir -p .state; chmod 700 .state; touch .state/tunnel.env; chmod 600 .state/tunnel.env)
```

Using a trusted local secret editor, save one literal `CONTROL_PLANE_API_KEY=...` assignment in `.state/tunnel.env`. Never paste the credential into chat, command arguments, logs or Git. Do not overwrite an existing file unnecessarily. This file must contain no commands or substitutions.

Set the verified client path and private tunnel ID locally; the ID below is a placeholder:

```sh
calendar_tunnel_client="/absolute/path/to/verified/tunnel-client"
calendar_mcp_command=$(python3 -c 'import pathlib,shlex; print(shlex.join([str(pathlib.Path.cwd()/"scripts/calendar-mcp"),"stdio","--port","8765"]))')
(
  set +x
  set -e
  unset CONTROL_PLANE_API_KEY
  set -a
  . "$PWD/.state/tunnel.env"
  set +a
  : "${CONTROL_PLANE_API_KEY:?runtime credential missing}"
  "$calendar_tunnel_client" runtimes connect \
    --alias calendar --profile calendar --profile-dir "$PWD/.state/tunnel-profiles" \
    --runtime-api-key env:CONTROL_PLANE_API_KEY \
    --tunnel-id YOUR_PRIVATE_TUNNEL_ID --mcp-command "$calendar_mcp_command"
)
"$calendar_tunnel_client" runtimes status calendar --json
```

Source only the trusted file you created, with tracing disabled. The profile references the environment variable, not the key. Check running/healthy/ready; recheck client help for your downloaded version. No `nohup` or `disown` is needed.

## 5. Add ChatGPT and verify discovery

Follow [ChatGPT connection steps](setup.md#7-add-the-private-tunnel-in-chatgpt) to add the same private tunnel in the intended workspace. The tunnel connection uses the workspace boundary; the local stdio adapter reads its own gateway token. Never paste that token into ChatGPT.

Confirm all 22 tools, including `list_unresolved_changes`, `preflight_reconciliation` and `commit_reconciliation`. Refresh definitions/check enabled toggles if that host has an older catalog. Tool discovery and tunnel health do not validate Calendar writes or complete mobile confirmation rendering. Start with explicitly scoped reads; any write needs an identified target, complete signed preview and the host's normal confirmation policy. Never blindly retry an uncertain result.

## 6. Optional login service

After manual setup works, [render and install the service](setup.md#optional-login-startup-recovery-and-local-alerts). Use the same state, helper, verified client, credential file, port 8765, alias `calendar` and profile `calendar`. Stage the configuration while manual setup is working; these commands use the same defaults as above:

```sh
./scripts/calendar-mcp service render \
  --helper "$PWD/build/Calendar MCP Helper.app/Contents/MacOS/CalendarHelper" \
  --tunnel-client "$calendar_tunnel_client" --tunnel-id YOUR_PRIVATE_TUNNEL_ID \
  --tunnel-env "$PWD/.state/tunnel.env" --profile-dir "$PWD/.state/tunnel-profiles" \
  --alias calendar --profile calendar --port 8765
```

Before installing, stop only your manual runtime and gateway:

```sh
"$calendar_tunnel_client" runtimes stop calendar
# Stop the foreground gateway with Ctrl-C in its Terminal.
```

Then run:

```sh
./scripts/calendar-mcp service install
./scripts/calendar-mcp service status
```

Do not run manual and service owners together. GUI login is required after reboot; the monitor does not supply pre-login access or request Calendar permission.
