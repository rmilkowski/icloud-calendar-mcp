# Optional Reminders extension

Reminders is an optional, nonrecurring extension implemented in source and **disabled by default**. No installed app, service, Calendar grant or live data has been changed for this work. Strict native, full Python and actual raw-helper integration validation have passed; this feature is not deployed and live provider behavior remains unverified. The settled Calendar installation continues to expose its existing 22 tools.

## Activation and OS access

After a separately authorized build/installation of the new settled app, explicit `--enable-reminders` on `serve` opts in. The same flag on `service render` persists an actual boolean `enable_reminders:true` in the protected service configuration and adds it to the gateway launch arguments. Old configurations without the key remain valid and disabled; false preserves the old launch arguments. Rendering never installs/restarts a service or requests OS access. Follow the existing reviewed service maintenance procedure before changing an installed configuration.

Use two separate ChatGPT plugins: the existing Calendar tunnel exposes only its 22 Calendar tools, and a second distinct private tunnel exposes only the 17 Reminders tools. Both adapters connect to the same gateway and native helper. No Apple password or separate Apple login is needed. Refresh each plugin's tool definitions after setup. Tool discovery does not grant OS access or validate a write.

First explicitly initialize the independent local Reminders credential. This preserves the existing Calendar credential and history; serving never creates a missing credential:

```sh
./scripts/calendar-mcp init --state-dir "/absolute/private/state" --enable-reminders
```

The existing `gateway.token` authorizes only Calendar `/mcp` and `/status`. Independent `reminders.token` authorizes only `/reminders/mcp` and `/reminders/status`; neither key is pasted into ChatGPT. The protected Unix endpoint and fixed adapter resource enforce the same separation as HTTP routes. Calendar stdio defaults to `--resource calendar`; Reminders must explicitly use `--resource reminders`.

The initialization and following commands are **future, attended setup examples after an explicitly authorized settled build**, not actions performed for this source work. Preserve the existing state, authority port and owner configuration:

```sh
./scripts/calendar-mcp serve \
  --helper "/absolute/settled/Calendar MCP Helper.app/Contents/MacOS/CalendarHelper" \
  --backend eventkit --state-dir "/absolute/private/state" --port 8765 \
  --enable-reminders
```

For the optional login service, render with the same existing private tunnel/configuration values after following the [service maintenance procedure](setup.md#optional-login-startup-recovery-and-local-alerts). Review the staged config/plists before installing:

```sh
./scripts/calendar-mcp service render \
  --helper "/absolute/settled/Calendar MCP Helper.app/Contents/MacOS/CalendarHelper" \
  --python "/absolute/configured/python" \
  --state-dir "/absolute/private/state" --port 8765 \
  --tunnel-client "/absolute/verified/tunnel-client" \
  --tunnel-id YOUR_EXISTING_PRIVATE_TUNNEL_ID \
  --tunnel-env "/absolute/private/tunnel.env" \
  --profile-dir "/absolute/private/tunnel-profiles" \
  --alias EXISTING_ALIAS --profile EXISTING_PROFILE --enable-reminders \
  --reminders-tunnel-id YOUR_DISTINCT_REMINDERS_TUNNEL_ID \
  --reminders-tunnel-env "/absolute/private/tunnel.env" \
  --reminders-profile-dir "/absolute/private/reminders-tunnel-profiles" \
  --reminders-alias reminders --reminders-profile reminders
```

The five `--reminders-*` options are all-or-none and require `--enable-reminders`. They persist an exact `reminders_tunnel` object with `tunnel_id`, `tunnel_env`, `profile_dir`, `alias` and `profile`. Use a distinct tunnel ID, alias and canonical profile directory; a profile name or protected runtime environment file may be reused. Only the existing two gateway/monitor LaunchAgents are rendered. The monitor tracks `reminders_tunnel` separately, with its own restart attempts, backoff, startup grace and incidents; reconfiguration preserves historical budgets. The new Reminders runtime must have an official managed JSON profile (`<profile>.yaml`) in an owned mode-`0700` directory, with an owned mode-`0600`, single-link regular file. Before recovery the monitor verifies exactly one `main` stdio command whose text exactly matches the service-generated canonical quoting for the configured Reminders adapter. Equivalent manual formatting is refused. Manual YAML dialects, alternate HTTP targets, extra channels and command changes fail closed. This checks configured ownership; it is not an OS sandbox against the same user editing both profile and service state. Existing Calendar profile handling remains compatible; its deferred protected-profile relocation is separate.

The official tunnel service supports one configured MCP target per tunnel ID. After separately arranging a second private tunnel and reviewing its official managed runtime/profile, its fixed target is:

```sh
/absolute/configured/python -m calendar_mcp stdio \
  --state-dir "/absolute/private/state" --port 8765 --resource reminders
```

For service management, the executable, arguments and canonical command quoting must match the rendered service configuration exactly (`--python` selects that interpreter); an equivalent wrapper command is not adopted automatically. The official managed runtime/profile must be prepared and reviewed before the service can own it; an absent profile is not proof of safe ownership. Follow the existing tunnel connection and stopped-runtime service cutover procedure using the distinct Reminders ID/alias/directory and this exact command. Keep the existing Calendar target unchanged. Add the distinct Reminders tunnel as a separate custom MCP plugin in ChatGPT, using the [same private-tunnel connection procedure](setup.md#7-add-the-private-tunnel-in-chatgpt). This source change does not create a tunnel, runtime credential, workspace connection or ChatGPT plugin.

For a future attended setup, run from this repository with the foreground gateway already using the same state/port and explicit Reminders opt-in. The distinct remote tunnel and runtime credential must already have been arranged through the official workspace setup. Prepare its owned runtime with the exact interpreter/arguments from the render command above:

```sh
reminders_python="/absolute/configured/python"
reminders_tunnel_client="/absolute/verified/tunnel-client"
reminders_mcp_command=$("$reminders_python" -c 'import pathlib,shlex,sys; print(shlex.join([str(pathlib.Path(sys.executable).resolve()),"-m","calendar_mcp","stdio","--state-dir","/absolute/private/state","--port","8765","--resource","reminders"]))')
mkdir -m 700 "/absolute/private/reminders-tunnel-profiles"
(
  set +x
  set -e
  unset CONTROL_PLANE_API_KEY
  set -a
  . "/absolute/private/tunnel.env"
  set +a
  : "${CONTROL_PLANE_API_KEY:?runtime credential missing}"
  "$reminders_tunnel_client" runtimes connect \
    --alias reminders --profile reminders \
    --profile-dir "/absolute/private/reminders-tunnel-profiles" \
    --runtime-api-key env:CONTROL_PLANE_API_KEY \
    --tunnel-id YOUR_DISTINCT_REMINDERS_TUNNEL_ID \
    --mcp-command "$reminders_mcp_command"
)
"$reminders_tunnel_client" runtimes status reminders --json
"$reminders_tunnel_client" runtimes stop reminders
```

Source only the trusted protected literal environment file with tracing disabled. Verify the prepared runtime's exact ownership and health before stopping it; preserve its profile for service ownership checks. The parent directory must already be private and owned. Apply the existing stopped-runtime cutover to the Calendar runtime and gateway as well. A failed/uncertain stop requires inspection, not installation over the live owner.

Use the normal reviewed `service install` procedure; do not run a foreground and service owner together. A later explicit OS authorization request for that final app uses:

```sh
/usr/bin/open -n -W -g "/absolute/settled/Calendar MCP Helper.app" \
  --args --authorize-reminders
```

Enabling the extension is a local configuration choice. It does not replace OS permission or the normal exact-preview host write-consent policy.

Disabled means no Reminders capability/authorization probes, state creation, data access or tools. Explicit opt-in against an older helper can fail as unsupported configuration; there is no automatic fallback, relaunch or hidden enabling. Exact native `reminders_capabilities` exposes seventeen tools only on the Reminders resource; the Calendar resource remains Calendar-only. An enabled gateway exposes supported tools even when the separate Reminders grant is missing, so journal status/history/assessment remain available after permission revocation. Provider operations return `reminders_access_required`; enabling and serving never request access.

Only a future, explicitly requested attended local `--authorize-reminders` action may request the final app's Reminders permission through LaunchServices. This is separate from Calendar Full Access and from consent to any particular change. Do not rebuild the current installed app, repeat OS prompts or grant unrelated host processes permission to try this source feature. No Reminders OS prompt or live validation is authorized by this document.

Calendar `status` remains Calendar-only. Reminders status is separately authenticated and available only when opted in. The monitor continues to assess Calendar/native availability; denied Reminders access is not a reason to restart Calendar services. Read the separate metadata with:

```sh
./scripts/calendar-mcp reminders status --state-dir /absolute/private/state --port 8765
```

## Supported data and changes

Use `list_reminder_lists`, `query_reminders` and `get_reminder` to identify one opaque reminder/list identity. Queries require one list, return at most 100 complete records and a truthful `truncated` flag, and have no pagination/all-results promise. Narrow filters when truncated. List discovery fails rather than silently dropping lists beyond 200. Recurring and unsupported-component reminders remain explicit in reads but are ineligible for writes, including complete/reopen. Unrepresentable dates are not silently treated as undated.

Writable fields are title, notes, integer priority 0–9, independently optional start/due components, and optional explicit absolute display alerts. Dates are null or exactly `{date,time,time_zone}`: a Gregorian `YYYY-MM-DD`, null or `HH:MM:SS` time, and null or IANA zone. Null time is date-only; null zone is floating. Named timed DST gaps/folds are rejected. There is no fabricated event end/duration or required start for a due date.

For a request that explicitly includes an alarm at **09:00 UTC**, an illustrative create preflight is:

```json
{"action":"create","scope":"this","list_id":"<opaque-list-id>","fields":{"title":"Reminder fixture","due":{"date":"2030-06-03","time":null,"time_zone":null},"alerts":[{"at":"2030-06-03T09:00:00Z"}]}}
```

A due date alone does not request a notification. Never choose an alarm time silently. Alerts are a complete replacement list of at most ten absolute `{at:<explicit-offset timestamp>}` objects; relative alerts are unsupported. Creation defaults to no alerts; omission during modification preserves all raw alarms and `[]` clears them. Supported local original alarms remain preserved on unrelated edits; email, procedure and unknown external-action alarms make every mutation ineligible; recovery is ineligible if native cannot reproduce the required raw alarms losslessly.

`preflight_reminder_change` supports create, modify, complete, reopen and delete with scope `this`. Create requires list ID and title; modification requires reminder ID and nonempty fields; complete/reopen/delete take the reminder ID without fields. No recurrence, list moves, direct completion-date edits, list/container creation/deletion, tags, subtasks, assignments or attachment operations are added.

Submit the complete returned preview through its dedicated `commit_reminder_create`, `commit_reminder_modify`, `commit_reminder_complete`, `commit_reminder_reopen` or `commit_reminder_delete` tool under the host's normal write-confirmation policy. Calendar commits reject Reminders previews, and Reminders commits reject Calendar previews. Preview arguments expose the complete supported before/after state, changed-field mask, completion-timestamp policy and recovery limitations; native authentication and refreshed provider checks remain authoritative. Ordinary completion chooses its timestamp immediately before provider mutation; the caller does not supply it. Host policy does not prove a fresh human click.

## Independent history, safety and recovery

The same helper process owns separate Reminders state at `native-<backend>/reminders/reminders.sqlite3`, with its own domain, lock, installation/signing identity, encrypted details/keys, journal, audit, replay claims and safety policy. Calendar payloads/history are never interpreted as reminder payloads or vice versa. Calendar's writer floor 7 and encoding 2 remain unchanged; the Reminders storage contract is independently version 1.

Reminders modify/complete/reopen and inverse modifications use its modify budget; deletion uses its delete budget; creation/recreation is additive. These budgets are separate from Calendar budgets, not a global cross-resource cap. Claim, quota and durable intent are atomic before provider mutation. Unknown outcomes, proven native non-entry and user-assessed outcomes remain distinct; no unknown/not-applied/assessment refunds a charge or reuses a nonce. Missing identity/list evidence blocks conservatively. Independent lists can proceed only when native proves independence.

The Reminders store uses its own protected local policy files, separate from the Calendar files:

- Retention: `<gateway-state>/native-<backend>/reminders/recovery-policy.json`.
- Write budgets: `<gateway-state>/native-<backend>/reminders/write-safety.json`.

For the default live state these are under `~/Library/Application Support/Private Calendar MCP/native-eventkit/reminders/`. Keep directories owned mode `0700` and policy files owned, single-link regular mode `0600`; no MCP tool or caller argument changes them. Missing retention selects five days. Its exact format is:

```json
{"version":1,"retention_days":5}
```

`retention_days` is an integer from 1 to 365. A change applies to future detail captures, cannot resurrect expired keys and does not remove unresolved holds or permanent nonce/quota/audit history.

The exact default Reminders budget format is:

```json
{"version":1,"delete_hour":50,"delete_day":200,"destructive_hour":100,"destructive_day":500}
```

The field bounds/adoption rules match the [Calendar policy format](setup.md#bulk-modify-and-delete-protection), but the file, adoption metadata and cumulative charges are independent. Limits are integers from 1 through 100000; each day limit must cover its hour limit and combined limits must cover delete limits. After a protected explicit policy is adopted, a missing/malformed policy fails closed for new writes. Policy changes never refund charges, reset watermarks or provide consent.

Use `get_reminder_change_status` with the original execution nonce after uncertainty, without retrying a mutation or preparing a replacement attempt. `list_reminder_changes`, `get_stored_reminder_change` and `list_unresolved_reminder_changes` inspect only the separate reminder journal. Details default to five-day encrypted retention; unresolved evidence and transitive recovery sources remain pinned, and minimal replay/outcome/quota history persists. Keys and ciphertext share the same protected account boundary; encryption is not isolation from a same-user attacker.

`preflight_reminder_rollback` accepts exactly one source `change_id`; there is no all/batch contract. It prepares one `commit_reminder_rollback` step from verified applied, retained, unchanged supported state without conflicting later history. Creation inverse deletes the still-unchanged created object; modify/complete/reopen inverse restores supported fields and exact retained completion state/date; deletion recovery creates a new nonrecurring object with a new identity. Full raw restoration details are signed and visible. Individual snapshots are bounded to 128 KiB, ordinary previews to 192 KiB, journal-assessment previews to 320 KiB and retained unknown results to 16 KiB of canonical UTF-8. Separate compact ASCII-escaped limits are 400 KiB for ordinary previews, 900 KiB for assessments and 32 KiB for unknown results; complete signed commit request UTF-8 frames stay within 512 KiB and the existing HTTP/stdin limit remains 1 MiB. Oversized values fail explicitly rather than truncating signed content. Hidden/private metadata and original list relationships are not restored or verified, and unsupported restoration fails before intent. Recovery executions themselves have no inverse-of-inverse feature.

For an unknown, inspect the source and obtain the user's explicit assessment/evidence before `preflight_reminder_reconciliation` and exact-preview `commit_reminder_reconciliation`. These are journal-only, with no provider verification, retry, fresh reminder mutation or automatic recovery. An uncertain assessment can replay only its exact authenticated preview for the stable receipt; source status uses the original nonce, not the assessment nonce.

Read-only local history/preparation is available without reading SQLite or keys:

```sh
./scripts/calendar-mcp reminders changes list --limit 50
./scripts/calendar-mcp reminders changes show ORIGINAL_CHANGE_ID
./scripts/calendar-mcp reminders changes status ORIGINAL_NONCE
./scripts/calendar-mcp reminders changes unresolved --limit 50
./scripts/calendar-mcp reminders changes prepare ORIGINAL_CHANGE_ID
```

Pass the same configured state/port to every command. There is no standalone commit-from-file command or Terminal write-consent flow; the MCP tools remain the normal write surface.

Backups/maintenance must preserve the **entire** Reminders subdirectory, including encrypted details/keys, nonces, proof/unknown evidence, audit, quotas and assessment receipts. Never restore an older state over newer authoritative history. The existing Calendar `--rotate-keys` flag is Calendar-only unless an explicit reminder equivalent is documented; do not claim it rotates Reminders keys. Each resource credential binding rotates only its own native signing generation on restart without erasing history. Rotating `gateway.token` does not rotate the Reminders binding; rotating `reminders.token` does not rotate the Calendar binding. Repair forward after committed migrations.

## Validation limits

Final split-plugin validation used the same newly built raw helper, SHA-256 `126fddc3920424a00d0f7541e3feb1dd57357613fdccd04fdf79af3e5cc06fa5`:

- Strict native suite: 374 tests, zero failures and zero skips; execution 26.376 seconds after a 13.233-second build.
- Full Python suite: 192 tests in 10.351 seconds; 189 passed and the three existing explicitly opt-in packaged LaunchServices tests were skipped. No feature test was skipped.
- Actual raw-helper tests exercised separate Calendar-only 22 and Reminders-only 17 catalogs, protected HTTP/stdio resource isolation, independent credential bindings, helper lifecycle, source/assessment replay and no-grant behavior. Existing reminder create/date/absolute-alert, modify, complete/reopen, one-source inverse, deletion-copy and history/status paths also executed.
- Service tests covered exact canonical command quoting, protected managed-profile ownership, independent restart budgets and preservation of existing monitor history. Official CLI help/local-only synthetic profile generation and narrowly sanitized read-only managed-profile schema inspection grounded the integration; no runtime was connected or controlled during that inspection.

XCTest-only exports created fresh private synthetic unknown states, closed every state owner and then opened the actual helper in synthetic mode. DEL/BMP/non-BMP sources passed full original-preview → unknown → host-visible assessment → journal commit and identical receipt replay. The original encrypted payload, single execution and quota charge remained preserved; exactly one assessment receipt was recorded, with no provider operation. The production helper has no fault/seed control. Pure native tests cover callback deadline/late-completion safety and exact public metadata witnesses, including external-action alarm refusal and preservation of supported local richer alarms.

The installed helper, signature, grants, credentials and service runtime were not rebuilt/replaced or changed. No ChatGPT plugin, private tunnel or remote credential was created; no tunnel was connected. The public EventKit adapter compiled, but no real EventKit fetch/mutation, account data, OS authorization prompt or live provider validation occurred.

These results establish source/synthetic behavior only. A future separately authorized settled build/installation, explicit activation, separate Reminders grant, intended host refresh and scoped live checks remain required. Provider date/component preservation, completion precision, alarm delivery, hidden/private metadata, recovery behavior and host confirmation rendering remain unverified.
