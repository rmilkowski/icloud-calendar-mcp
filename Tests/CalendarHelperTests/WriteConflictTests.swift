import XCTest
import Foundation
import CryptoKit
@testable import CalendarCore

final class WriteConflictTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() { for directory in directories { try? FileManager.default.removeItem(at: directory) }; super.tearDown() }
    private func store() throws -> StateStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-conflicts-" + UUID().uuidString)
        directories.append(dir)
        let state = try StateStore(directory: dir)
        try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "a", count: 64)); return state
    }
    private func record(_ group: String, calendar: String = "synthetic-calendar", occurrence: String? = nil, detached: Bool = false) -> EventRecord {
        EventRecord(nativeID: group, calendarNativeID: calendar, occurrence: occurrence,
                    fields: EventFields(title: group, start: occurrence ?? "2026-10-25T10:00:00Z", end: "2026-10-25T11:00:00Z", timeZone: "Europe/London", allDay: false), recurring: occurrence != nil, detached: detached)
    }
    private func call(_ broker: Broker, _ op: String, _ args: [String: JSON] = [:]) -> JSON {
        broker.handle(.object(["op": .string(op), "arguments": .object(args)]))
    }
    private func preview(_ broker: Broker, _ id: JSON, title: String = "Changed") -> JSON {
        call(broker, "preflight_change", ["action": .string("modify"), "scope": .string("this"), "event_id": id, "fields": .object(["title": .string(title)])])["result"]["preview"]
    }
    private func commit(_ broker: Broker, _ preview: JSON) -> JSON { call(broker, "commit_modify", ["preview": preview]) }
    private func legacyPreview(_ preview: JSON, state: StateStore) throws -> JSON {
        var fields = preview["envelope"].object!
        fields["version"] = .int(1); fields.removeValue(forKey: "recovery")
        let body = JSON.object(fields), key = SymmetricKey(data: Data(base64Encoded: try state.metadata("signing_key")!)!)
        return .object(["envelope": body, "authentication_tag": .string(Data(HMAC<SHA256>.authenticationCode(for: try body.data(), using: key)).base64EncodedString())])
    }
    private func payload(_ state: StateStore, group: String, calendar: String = "synthetic-calendar", occurrence: String? = nil, action: String = "modify") throws -> JSON {
        let cal = try state.identity(kind: "calendar", nativeID: calendar)
        var value: [String: JSON] = ["action": .string(action), "calendar": .object(["id": .string(cal)])]
        if action != "create" { value["before"] = .object(["id": .string(try state.identity(kind: "event", nativeID: group, calendarID: calendar, occurrence: occurrence))]) }
        return .object(value)
    }
    @discardableResult private func unknown(_ state: StateStore, _ payload: JSON) throws -> String {
        let nonce = UUID().uuidString
        _ = try state.claim(nonce: nonce, payload: payload, now: Date())
        try state.finish(nonce: nonce, state: "unknown", result: .object(["state": .string("unknown")]), event: "synthetic_unknown")
        return nonce
    }
    private func rejects(_ state: StateStore, _ payload: JSON, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try state.assertNoUnresolvedConflict(payload: payload), file: file, line: line) { error in
            XCTAssertEqual((error as? CoreError)?.code, "unresolved_write", file: file, line: line)
        }
    }
    private func fixtureMarker(_ state: StateStore, calendar: JSON = .null, scope: JSON? = nil, sources: [String] = [], nonce: String = UUID().uuidString) throws -> String {
        var marker: [String: JSON] = ["storage_version": .int(2), "action": .string("modify"), "payload_digest": .string(String(repeating: "a", count: 64)), "calendar_id": calendar]
        if let scope { marker["conflict_scope"] = scope }
        if !sources.isEmpty { marker["rollback_of"] = .array(sources.map(JSON.string)) }
        try state.execute("INSERT INTO executions(nonce,payload,state,result,created) VALUES(?,?,'unknown',?,?)", [nonce, try JSON.object(marker).text(), try JSON.object(["storage_version": .int(2), "state": .string("unknown")]).text(), iso(Date())])
        return nonce
    }

    func testSameCalendarPreobservedIndependentEventsProceedAndUnknownReplayKeepsQuota() throws {
        let state = try store(), base = SyntheticBackend(events: [record("ExistingGroupA"), record("ExistingGroupB")]), broker = Broker(state: state, backend: base)
        let a = try broker.view(base.events[0]), b = try broker.view(base.events[1])
        let draft = preview(broker, a["id"])
        base.throwAfterWrite = true
        let result = commit(broker, draft)
        XCTAssertEqual(result["result"]["state"], .string("unknown"))
        let immutable = try state.rows("SELECT payload FROM executions")[0][0]
        base.throwAfterWrite = false
        XCTAssertEqual(commit(broker, preview(broker, b["id"]))["result"]["state"], .string("applied"))
        XCTAssertEqual(commit(broker, draft), result); XCTAssertEqual(base.writeCount, 2)
        XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], "2")
        XCTAssertEqual(try state.rows("SELECT payload FROM executions WHERE nonce=?", [result["result"]["nonce"].string!])[0][0], immutable)
        XCTAssertTrue(try state.hasUnresolved()); try state.verifyAudit()
        let marker = try JSON.parse(Data(immutable.utf8))
        XCTAssertEqual(marker["storage_version"], .int(2)); XCTAssertEqual(marker["conflict_scope"]["version"], .int(1))
        XCTAssertEqual(try state.execution(result["result"]["nonce"].string!)?.payload, draft["envelope"])
        XCTAssertEqual(try state.payloadMatches(nonce: result["result"]["nonce"].string!, payload: draft["envelope"]), true)
        XCTAssertEqual(draft["envelope"]["conflict_scope"], .null)
        XCTAssertFalse(try state.auditRecords().contains { $0["payload"]["conflict_scope"] != .null })
    }

    func testWholeNativeGroupBlocksOtherOccurrencesAndDetachedIdentities() throws {
        let state = try store(), a = try payload(state, group: "series", occurrence: "first")
        let sibling = try payload(state, group: "series", occurrence: "second"), detached = try payload(state, group: "series", occurrence: "detached")
        try unknown(state, a); rejects(state, sibling); rejects(state, detached)
    }

    func testNewGroupCannotBecomeIndependentWitnessAfterUnknownButNewOccurrenceOfOldGroupCan() throws {
        let state = try store(), a = try payload(state, group: "unknown")
        _ = try payload(state, group: "known-independent", occurrence: "selected")
        try unknown(state, a)
        rejects(state, try payload(state, group: "possible-output-alias"))
        XCTAssertNoThrow(try state.assertNoUnresolvedConflict(payload: payload(state, group: "known-independent", occurrence: "new-first-anchor")))
    }

    func testAffectedIdentityRebindRetainsFrozenAndCurrentGroups() throws {
        let state = try store(), a = try payload(state, group: "old-group")
        let possible = try payload(state, group: "rebound-group", occurrence: "sibling")
        let oldSibling = try payload(state, group: "old-group", occurrence: "sibling")
        try unknown(state, a)
        let id = a["before"]["id"].string!, rowID = try state.rows("SELECT rowid FROM identities WHERE id=?", [id])[0][0]
        try state.rebindEvent(id: id, to: record("rebound-group"))
        XCTAssertEqual(try state.rows("SELECT rowid FROM identities WHERE id=?", [id])[0][0], rowID)
        rejects(state, possible); rejects(state, oldSibling)
    }

    func testVerifiedIndependentRebindPreservesWitnessProvenance() throws {
        let state = try store(), a = try payload(state, group: "unknown"), b = try payload(state, group: "independent")
        try unknown(state, a)
        let id = b["before"]["id"].string!, rowID = try state.rows("SELECT rowid FROM identities WHERE id=?", [id])[0][0]
        try state.rebindEvent(id: id, to: record("verified-new-group"))
        XCTAssertEqual(try state.rows("SELECT rowid FROM identities WHERE id=?", [id])[0][0], rowID)
        XCTAssertNoThrow(try state.assertNoUnresolvedConflict(payload: b))
    }

    func testLegacyScopeHasOnlyCalendarFallbackAndMissingCalendarHasGlobalFallback() throws {
        for trusted in [true, false] {
            let state = try store(), same = try payload(state, group: "same"), other = try payload(state, group: "other", calendar: "other-calendar")
            _ = try fixtureMarker(state, calendar: trusted ? same["calendar"]["id"] : .string("unknown-calendar"))
            rejects(state, same)
            if trusted { XCTAssertNoThrow(try state.assertNoUnresolvedConflict(payload: other)) } else { rejects(state, other) }
        }
    }

    func testPresentMalformedScopeFailsClosedEvenAcrossCalendars() throws {
        for scope in [JSON.null, .object(["version": .int(99)]), .string("invalid")] {
            let state = try store(), a = try payload(state, group: "a"), b = try payload(state, group: "b", calendar: "other-calendar")
            _ = try fixtureMarker(state, calendar: a["calendar"]["id"], scope: scope); rejects(state, b)
        }
    }

    func testMissingTargetGroupFallsBackToCalendarAndUntrustedCalendarBlocksGlobally() throws {
        let state = try store(), a = try payload(state, group: "a"), b = try payload(state, group: "b"), other = try payload(state, group: "c", calendar: "other-calendar")
        var missing = a.object!; missing["before"] = .object(["id": .string(UUID().uuidString)])
        try unknown(state, .object(missing)); rejects(state, b)
        XCTAssertNoThrow(try state.assertNoUnresolvedConflict(payload: other))
        var untrusted = other.object!; untrusted["calendar"] = .object(["id": .string("not-native")]); rejects(state, .object(untrusted))
    }

    func testCreateAndRestoreCreateHaveNoSameCalendarIndependenceWitness() throws {
        let state = try store(), existing = try payload(state, group: "existing"), create = try payload(state, group: "", action: "create")
        let otherCreate = try payload(state, group: "", calendar: "other-calendar", action: "create")
        try unknown(state, existing); rejects(state, create)
        XCTAssertNoThrow(try state.assertNoUnresolvedConflict(payload: otherCreate))
        var restore = create.object!; restore["rollback"] = .object(["source_change_ids": .array([])])
        rejects(state, .object(restore))
    }

    func testUnknownCreateAllowsOnlyPreexistingIndependentExistingTarget() throws {
        let state = try store(), old = try payload(state, group: "old")
        try unknown(state, payload(state, group: "", action: "create"))
        XCTAssertNoThrow(try state.assertNoUnresolvedConflict(payload: old))
        rejects(state, try payload(state, group: "possible-created-output"))
        rejects(state, try payload(state, group: "", action: "create"))
    }

    func testRollbackUnionsOriginalIdentitiesAndAncestorDependencies() throws {
        let state = try store(), a = try payload(state, group: "original"), b = try payload(state, group: "independent")
        let source = UUID().uuidString
        _ = try state.claim(nonce: source, payload: a, now: Date())
        try state.finish(nonce: source, state: "applied", result: .object([:]), event: "synthetic_applied")
        var inverse = b.object!; inverse["rollback"] = .object(["source_change_ids": .array([.string(source)])])
        let child = try unknown(state, .object(inverse))
        rejects(state, a); rejects(state, b)
        var descendant = try payload(state, group: "other", calendar: "other-calendar").object!
        descendant["rollback"] = .object(["source_change_ids": .array([.string(source)])]); rejects(state, .object(descendant))
        let scope = try JSON.parse(Data(state.rows("SELECT payload FROM executions WHERE nonce=?", [child])[0][0].utf8))["conflict_scope"]
        XCTAssertTrue(scope["event_ids"].array!.contains(a["before"]["id"]))
        XCTAssertTrue(scope["nonces"].array!.contains(.string(source)))
    }

    func testMissingCyclicAndMalformedDependencyEvidenceFailsClosed() throws {
        let state = try store(), a = try payload(state, group: "a")
        var candidate = a.object!; candidate["rollback"] = .object(["source_change_ids": .array([.string("missing")])])
        XCTAssertThrowsError(try state.claim(nonce: UUID().uuidString, payload: .object(candidate), now: Date()))
        candidate["rollback"] = .object(["source_change_ids": .array([.int(1)])])
        XCTAssertThrowsError(try state.claim(nonce: UUID().uuidString, payload: .object(candidate), now: Date()))
        let cycle = UUID().uuidString
        let marker: JSON = .object(["storage_version": .int(2), "action": .string("modify"), "payload_digest": .string(String(repeating: "a", count: 64)), "calendar_id": a["calendar"]["id"], "rollback_of": .array([.string(cycle)])])
        try state.execute("INSERT INTO executions VALUES(?,?,'unknown',?,?)", [cycle, try marker.text(), try JSON.object(["storage_version": .int(2)]).text(), iso(Date())])
        rejects(state, try payload(state, group: "b", calendar: "other-calendar"))
    }

    func testClaimRejectsBeforeQuotaPolicyAdoptionAuditOrNonce() throws {
        let state = try store(), a = try payload(state, group: "a")
        try unknown(state, a)
        let policy: JSON = .object(["version": .int(1), "delete_hour": .int(1), "delete_day": .int(1), "destructive_hour": .int(2), "destructive_day": .int(2)])
        let path = state.directory.appendingPathComponent("write-safety.json")
        try policy.data().write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let revision = try state.metadata("write_safety_revision")
        let before = try state.rows("SELECT (SELECT count(*) FROM executions),(SELECT count(*) FROM write_safety_claims),(SELECT count(*) FROM audit)")
        let nonce = UUID().uuidString
        XCTAssertThrowsError(try state.claim(nonce: nonce, payload: a, now: Date()))
        XCTAssertEqual(try state.rows("SELECT (SELECT count(*) FROM executions),(SELECT count(*) FROM write_safety_claims),(SELECT count(*) FROM audit)"), before)
        XCTAssertNil(try state.execution(nonce))
        XCTAssertEqual(try state.metadata("write_safety_revision"), revision)
        XCTAssertEqual(try state.metadata("write_safety_file_adopted"), "false")
        XCTAssertThrowsError(try state.claim(nonce: UUID().uuidString, payload: payload(state, group: "late"), now: Date()))
    }

    func testExactSeriesReferenceAndAnchorMustShareNativeCalendarGroup() throws {
        let state = try store(), a = try payload(state, group: "a"), b = try payload(state, group: "b")
        var forged = a.object!; forged["version"] = .int(4); forged["series"] = .object(["selected": b["before"]])
        XCTAssertThrowsError(try state.claim(nonce: UUID().uuidString, payload: .object(forged), now: Date())) { error in XCTAssertEqual((error as? CoreError)?.code, "invalid_preview") }
        XCTAssertTrue(try state.rows("SELECT nonce FROM executions").isEmpty)
    }

    func testNewSeriesAnchorUsesPreexistingSelectedGroupWitness() throws {
        let state = try store(), a = try payload(state, group: "unknown"), selected = try payload(state, group: "independent-series", occurrence: "selected")
        try unknown(state, a)
        var candidate = try payload(state, group: "independent-series", occurrence: "new-anchor").object!
        candidate["version"] = .int(4); candidate["series"] = .object(["selected": selected["before"]])
        XCTAssertNoThrow(try state.assertNoUnresolvedConflict(payload: .object(candidate)))
        XCTAssertNoThrow(try state.claim(nonce: UUID().uuidString, payload: .object(candidate), now: Date()))
    }

    func testMalformedPresentScopeCannotOmitMarkerOrRetainedIdentityLineage() throws {
        for mutation in ["own_nonce", "bad_uuid", "future_cutoff", "wrong_action", "missing_event", "missing_source", "incomplete_mixed_group", "wrong_calendar"] {
            let state = try store(), a = try payload(state, group: "a"), b = try payload(state, group: "b", calendar: "other-calendar")
            let nonce = UUID().uuidString
            var marker = try state.conflictMarker(payload: a, nonce: nonce).object!, scope = marker["conflict_scope"]!.object!
            switch mutation {
            case "own_nonce": scope["nonces"] = .array([])
            case "bad_uuid": scope["event_ids"] = .array([.string("invalid")])
            case "future_cutoff": scope["identity_cutoff"] = .int(Int.max)
            case "wrong_action": scope["existing_target"] = .bool(false)
            case "missing_event": scope["event_ids"] = .array([.string(UUID().uuidString)])
            case "incomplete_mixed_group":
                scope["complete"] = .bool(false)
                scope["groups"] = .array([.object(["calendar": .string("other-calendar"), "item": .string("b")])])
            case "wrong_calendar":
                scope["calendar"] = .string("other-calendar")
                scope["groups"] = .array([.object(["calendar": .string("other-calendar"), "item": .string("b")])])
            default: marker["rollback_of"] = .array([.string(UUID().uuidString)])
            }
            marker["conflict_scope"] = .object(scope)
            try state.execute("INSERT INTO executions VALUES(?,?,'unknown',?,?)", [nonce, try JSON.object(marker).text(), try JSON.object(["storage_version": .int(2)]).text(), iso(Date())])
            rejects(state, b)
        }
    }

    func testOversizedFootprintAndDeepDependenciesRejectBeforeAccounting() throws {
        for deep in [false, true] {
            let state = try store()
            var candidate = try payload(state, group: deep ? "ordinary" : String(repeating: "x", count: 270_000)).object!
            if deep {
                var source: String?
                for _ in 0..<130 {
                    let nonce = UUID().uuidString
                    var marker: [String: JSON] = ["storage_version": .int(2), "action": .string("modify"), "payload_digest": .string(String(repeating: "a", count: 64)), "calendar_id": candidate["calendar"]!["id"]]
                    if let source { marker["rollback_of"] = .array([.string(source)]) }
                    try state.execute("INSERT INTO executions VALUES(?,?,'applied',?,?)", [nonce, try JSON.object(marker).text(), try JSON.object(["storage_version": .int(2)]).text(), iso(Date())])
                    source = nonce
                }
                candidate["rollback"] = .object(["source_change_ids": .array([.string(source!)])])
            }
            let before = try state.rows("SELECT (SELECT count(*) FROM executions),(SELECT count(*) FROM write_safety_claims),(SELECT count(*) FROM audit),(SELECT count(*) FROM execution_keys)")
            XCTAssertThrowsError(try state.claim(nonce: UUID().uuidString, payload: .object(candidate), now: Date())) { error in XCTAssertEqual((error as? CoreError)?.code, "unresolved_write") }
            XCTAssertEqual(try state.rows("SELECT (SELECT count(*) FROM executions),(SELECT count(*) FROM write_safety_claims),(SELECT count(*) FROM audit),(SELECT count(*) FROM execution_keys)"), before)
        }
    }

    func testRestartPreservesScopeLegacyEnvelopeReplayAndRejectsCallerScopeInjection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-conflict-restart-" + UUID().uuidString)
        directories.append(dir)
        let base = SyntheticBackend(events: [record("unknown"), record("independent")])
        let original: JSON, originalResult: JSON, independent: JSON, immutable: [[String]]
        do {
            let state = try StateStore(directory: dir)
            try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "a", count: 64))
            let broker = Broker(state: state, backend: base), a = try broker.view(base.events[0]), b = try broker.view(base.events[1])
            original = try legacyPreview(preview(broker, a["id"]), state: state)
            independent = try legacyPreview(preview(broker, b["id"]), state: state)
            XCTAssertEqual(original["envelope"]["version"], .int(1))
            base.throwAfterWrite = true; originalResult = commit(broker, original); base.throwAfterWrite = false
            XCTAssertEqual(originalResult["result"]["state"], .string("unknown"))
            immutable = try state.rows("SELECT e.payload,d.payload_cipher,k.key FROM executions e JOIN execution_details d USING(nonce) JOIN execution_keys k USING(nonce) WHERE nonce=?", [original["envelope"]["nonce"].string!])
        }
        let state = try StateStore(directory: dir)
        try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "a", count: 64))
        let broker = Broker(state: state, backend: base)
        var injectedEnvelope = independent["envelope"].object!, injectedPreview = independent.object!
        injectedEnvelope["conflict_scope"] = .object(["version": .int(1), "identity_cutoff": .int(Int.max)])
        injectedPreview["envelope"] = .object(injectedEnvelope)
        XCTAssertNotEqual(commit(broker, .object(injectedPreview))["error"], .null)
        XCTAssertEqual(call(broker, "commit_modify", ["preview": independent, "conflict_scope": .object([:])])["error"]["code"], .string("invalid_arguments"))
        XCTAssertEqual(commit(broker, original), originalResult)
        XCTAssertEqual(commit(broker, independent)["result"]["state"], .string("applied"))
        XCTAssertEqual(try state.rows("SELECT e.payload,d.payload_cipher,k.key FROM executions e JOIN execution_details d USING(nonce) JOIN execution_keys k USING(nonce) WHERE nonce=?", [original["envelope"]["nonce"].string!]), immutable)
        XCTAssertTrue(try state.hasUnresolved()); XCTAssertEqual(base.writeCount, 2)
        XCTAssertEqual(try state.metadata("recovery_storage_version"), "7")
    }
}
