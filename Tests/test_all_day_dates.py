"""Civil all-day contracts use neutral fixtures and synthetic providers only."""
from copy import deepcopy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest

from calendar_mcp.adapter import GatewayClient, run_stdio
from calendar_mcp.native import (ALL_DAY_DATES_CAPABILITIES, RECOVERY_CAPABILITIES,
    NativeBroker, NativeError, valid_all_day_dates_capabilities)
from calendar_mcp.protocol import Protocol, loads
from calendar_mcp.schema import (ALL_DAY_LIMITATION, ALL_DAY_READBACK_ENDS,
    FUTURE_TERMINATION_TOOLS, ValidationError, validate_arguments)
from calendar_mcp.security import initialize, read_token
from calendar_mcp.server import GatewayServer, MAX_RESPONSE
from Tests.test_alerts import request
from Tests.test_changes import recovery_preview
from Tests.test_future_termination import TerminationBroker
from Tests.test_native_integration import HELPER
from Tests.test_recurrence import ordinary_preview


def civil_preview(action="modify", rollback=False):
    preview = recovery_preview(action)
    e = preview["envelope"]
    e.pop("rollback")
    e.update(version=7, scope="this")
    if e["before"] is not None:
        e["before"]["fields"].update(start="2028-01-01T00:00:00Z", end="2028-01-01T23:59:59Z", all_day=True, time_zone=None)
    e["after"] = {"title": "Civil fixture", "start": "2028-01-03T00:00:00Z", "end": "2028-01-03T23:59:59Z",
                  "all_day": True, "time_zone": None, "location": "", "notes": ""}
    e["all_day"] = {"version": 1, "semantics": "floating_civil_dates", "projection_time_zone": "UTC",
        "before": None if action == "create" else {"start_date": "2028-01-01", "end_date_exclusive": "2028-01-02"},
        "after": {"start_date": "2028-01-03", "end_date_exclusive": "2028-01-04"},
        "write_end": "inclusive_last_second", "readback_ends": list(ALL_DAY_READBACK_ENDS)}
    e["recovery"] = {"mode": "not_applicable" if action == "create" else "all_day_fields",
                     "limitations": [] if action == "create" else [ALL_DAY_LIMITATION]}
    if action == "create":
        e["after"]["alerts"] = []
    if rollback:
        e["rollback"] = {"selection_id": "selection", "source_change_ids": ["source"], "source_digest": "a" * 64,
            "restoration": None, "limitations": [ALL_DAY_LIMITATION], "alarm_restoration": []}
    return preview


class CivilBroker(TerminationBroker):
    def recovery_capabilities(self): return {**RECOVERY_CAPABILITIES, "storage_version": 6}
    def all_day_dates_capabilities(self): return deepcopy(ALL_DAY_DATES_CAPABILITIES)


class CivilDateSchemaTests(unittest.TestCase):
    def validate(self, name, arguments):
        validate_arguments(name, arguments, recurrence=True, series_modification=True,
                           future_modification=True, future_termination=True, all_day_dates=True)

    def test_explicit_civil_input_exclusive_bounds_and_no_mixed_temporal_fields(self):
        base = {"action": "create", "scope": "this", "calendar_id": "calendar", "fields": {
            "title": "Fixture", "all_day_dates": {"start_date": "2028-02-28", "end_date_exclusive": "2028-03-01"}}}
        self.validate("preflight_change", base)
        ancient=deepcopy(base);ancient["fields"]["all_day_dates"]={"start_date":"1582-09-30","end_date_exclusive":"1583-10-01"}
        self.validate("preflight_change", ancient)  # 366 proleptic Gregorian labels.
        self.validate("preflight_change", {"action": "modify", "scope": "this", "event_id": "event", "fields": base["fields"]})
        for dates in ({"start_date":"1500-02-29","end_date_exclusive":"1500-03-01"},
                      {"start_date":"1582-09-30","end_date_exclusive":"1583-10-11"},
                      {"start_date": "2028-01-01"}, {"start_date": "2028-02-30", "end_date_exclusive": "2028-03-01"},
                      {"start_date": "2028-01-01", "end_date_exclusive": "2028-01-01"},
                      {"start_date": "2028-01-01", "end_date_exclusive": "2029-01-02"}):
            bad=deepcopy(base);bad["fields"]["all_day_dates"]=dates
            with self.assertRaises(ValidationError): self.validate("preflight_change", bad)
        for name,value in (("start","2028-01-01T00:00:00Z"),("end","2028-01-02T00:00:00Z"),
                           ("all_day",True),("time_zone",None),("recurrence",{"frequency":"daily"})):
            bad=deepcopy(base);bad["fields"][name]=value
            with self.assertRaises(ValidationError): self.validate("preflight_change", bad)
        for scope in ("series","future"):
            with self.assertRaises(ValidationError): self.validate("preflight_change", {**base,"scope":scope})
        with self.assertRaises(ValidationError):
            self.validate("preflight_change", {"action":"create","scope":"this","calendar_id":"c","fields":{
                "title":"F","start":"2028-01-01T00:00:00Z","end":"2028-01-02T00:00:00Z","all_day":True,"time_zone":None}})

    def test_v7_routes_exact_contract_inverse_and_retained_text(self):
        for action,rollback,name in (("create",False,"commit_create"),("modify",False,"commit_modify"),("modify",True,"commit_rollback")):
            preview=civil_preview(action,rollback)
            self.validate(name,{"preview":preview})
            for old in ("commit_delete","commit_series_modify","commit_series_rollback","commit_future_modify","commit_future_rollback","commit_future_delete","commit_future_restore"):
                with self.subTest(tool=old),self.assertRaises(ValidationError): self.validate(old,{"preview":preview})
            mutations=[lambda e:e.update(scope="future"),lambda e:e["all_day"]["readback_ends"].reverse(),
                lambda e:e["all_day"].update(write_end="exclusive_midnight"),lambda e:e["all_day"].update(extra=True),
                lambda e:e["after"].update(time_zone="UTC"),lambda e:e["after"].update(all_day=False),
                lambda e:e["all_day"]["after"].update(end_date_exclusive=e["all_day"]["after"]["start_date"])]
            if action=="modify": mutations.extend([lambda e:e["before"].update(recurring=True),lambda e:e["recovery"]["limitations"].clear()])
            if rollback: mutations.extend([lambda e:e["rollback"].update(source_change_ids=["one","two"]),lambda e:e["after"].update(alerts=[])])
            for mutation in mutations:
                bad=deepcopy(preview);mutation(bad["envelope"])
                with self.assertRaises(ValidationError): self.validate(name,{"preview":bad})
        inverse=civil_preview(rollback=True);inverse["envelope"]["after"]["notes"]="n"*20000
        self.validate("commit_rollback",{"preview":inverse})
        # Old signed contracts must still reach native exact-nonce replay checks.
        self.validate("commit_modify",{"preview":ordinary_preview("modify")})

    def test_capability_is_exact_cached_independent_and_old_floor_fails_closed(self):
        invalid=[None,{**ALL_DAY_DATES_CAPABILITIES,"version":True},{**ALL_DAY_DATES_CAPABILITIES,"storage_version":5},
                 {**ALL_DAY_DATES_CAPABILITIES,"preview_version":7.0},{**ALL_DAY_DATES_CAPABILITIES,"date_fields":["end_date_exclusive","start_date"]},
                 {**ALL_DAY_DATES_CAPABILITIES,"extra":True}]
        for value in [ALL_DAY_DATES_CAPABILITIES,*invalid,NativeError("unknown_operation","Old helper")]:
            broker=object.__new__(NativeBroker);calls=[]
            def call(name,arguments):
                calls.append((name,arguments))
                if isinstance(value,Exception): raise value
                return value
            broker.call=call;expected=value if value is ALL_DAY_DATES_CAPABILITIES else None
            self.assertEqual(broker.all_day_dates_capabilities(),expected);self.assertEqual(broker.all_day_dates_capabilities(),expected)
            self.assertEqual(calls,[("all_day_dates_capabilities",{})])
        for value in invalid:
            broker=CivilBroker();broker.all_day_dates_capabilities=lambda:value;broker.call=lambda *_:self.fail("Unsupported dispatch")
            result=Protocol(broker).handle(request("commit_create",{"preview":civil_preview("create")}))["result"]
            self.assertEqual(json.loads(result["content"][0]["text"])["code"],"feature_unavailable")
        old=CivilBroker();old.recovery_capabilities=lambda:{**RECOVERY_CAPABILITIES,"storage_version":5}
        old.all_day_dates_capabilities=lambda:self.fail("Old floor probed civil dates")
        self.assertEqual(Protocol(old).tools,FUTURE_TERMINATION_TOOLS)


class CivilDateHTTPTests(unittest.TestCase):
    def test_same_nineteen_tools_and_complete_v7_stdio_round_trip(self):
        with tempfile.TemporaryDirectory(prefix="calendar civil transport ") as directory:
            state=initialize(Path(directory)/"state");broker=CivilBroker();protocol=Protocol(broker)
            server=GatewayServer(0,read_token(state),protocol,state_directory=state)
            thread=threading.Thread(target=server.serve_forever,kwargs={"poll_interval":.01},daemon=True);thread.start()
            try:
                client=GatewayClient(state,server.server_port);wire=json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/list"}).encode()
                result=client.send(wire);self.assertEqual(len(result["result"]["tools"]),19)
                self.assertLess(len(json.dumps(result).encode()),MAX_RESPONSE);self.assertEqual(loads(json.dumps(result),max_depth=32),result)
                for action,rollback,name in (("create",False,"commit_create"),("modify",False,"commit_modify"),("modify",True,"commit_rollback")):
                    preview=civil_preview(action,rollback);call=request(name,{"preview":preview});sink=io.BytesIO()
                    self.assertEqual(run_stdio(client,io.BytesIO(json.dumps(call).encode()+b"\n"),sink),0)
                    self.assertFalse(json.loads(sink.getvalue())["result"]["isError"]);self.assertEqual(broker.received,(name,{"preview":preview}))
                    protocol.handle(call);self.assertIs(broker.received[1]["preview"],preview)
            finally: server.shutdown();server.server_close();thread.join()

@unittest.skipUnless(HELPER.is_file(), "Build native helper for synthetic civil-date integration")
class NativeCivilDateTests(unittest.TestCase):
    def test_create_date_edit_inverse_and_replay_use_full_v7_previews(self):
        with tempfile.TemporaryDirectory(prefix="calendar civil lifecycle ") as directory:
            broker=NativeBroker(HELPER,Path(directory)/"native","synthetic",credential_binding=hashlib.sha256(b"civil-fixture").hexdigest())
            self.addCleanup(broker.close)
            if broker.all_day_dates_capabilities() is None: self.skipTest("Selected helper lacks civil-date support")
            protocol=Protocol(broker);self.assertEqual(len(protocol.tools),19)
            def tool(name,args=None):
                reply=protocol.handle(request(name,args));self.assertNotIn("error",reply,reply)
                self.assertFalse(reply["result"]["isError"],reply);return reply["result"]["structuredContent"]
            calendar=tool("list_calendars")["calendars"][0]["id"]
            dates={"start_date":"2030-03-20","end_date_exclusive":"2030-03-23"}
            draft=tool("preflight_change",{"action":"create","scope":"this","calendar_id":calendar,"fields":{"title":"Civil fixture","all_day_dates":dates,"alerts":[]}})["preview"]
            self.assertEqual(draft["envelope"]["version"],7);self.assertEqual(draft["envelope"]["all_day"]["after"],dates)
            created=tool("commit_create",{"preview":draft});self.assertEqual(created["state"],"applied")
            self.assertEqual(tool("commit_create",{"preview":draft}),created)
            changed_dates={"start_date":"2030-03-21","end_date_exclusive":"2030-03-25"}
            draft=tool("preflight_change",{"action":"modify","scope":"this","event_id":created["event"]["id"],"fields":{"all_day_dates":changed_dates,"notes":"Changed fixture"}})["preview"]
            self.assertEqual(draft["envelope"]["all_day"]["before"],dates)
            changed=tool("commit_modify",{"preview":draft});self.assertEqual(changed["state"],"applied")
            self.assertEqual(tool("commit_modify",{"preview":draft}),changed)
            plan=tool("preflight_rollback",{"change_ids":[changed["nonce"]]});step=plan["steps"][0]
            self.assertEqual(step["commit_tool"],"commit_rollback");self.assertEqual(step["preview"]["envelope"]["all_day"]["after"],dates)
            restored=tool("commit_rollback",{"preview":step["preview"]});self.assertEqual(restored["state"],"applied")
            self.assertEqual(tool("commit_rollback",{"preview":step["preview"]}),restored)
            self.assertIsNone(restored["event"]["fields"]["time_zone"]);self.assertTrue(restored["event"]["fields"]["all_day"])
            self.assertEqual(restored["event"]["details"]["alarms"],created["event"]["details"]["alarms"])
