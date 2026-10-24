import AppKit
import Foundation
import CalendarCore
import Darwin

/// The only socket command opens a native window. It cannot submit a selection,
/// preview, approval, retention change or write request.
final class LocalRecoverySocket: @unchecked Sendable {
    private let descriptor: Int32
    private let path: String
    private let identity: LocalRecoverySocketIdentity
    init(directory: URL, openWindow: @escaping @MainActor @Sendable () -> Void) throws {
        let socketDirectory = try localRecoverySocketDirectory(stateDirectory: directory)
        var parent = stat()
        if lstat(socketDirectory.path, &parent) != 0 {
            guard errno == ENOENT, mkdir(socketDirectory.path, 0o700) == 0 else { throw CoreError("unsafe_state", "Cannot create protected local UI directory") }
            guard lstat(socketDirectory.path, &parent) == 0 else { throw CoreError("unsafe_state", "Cannot inspect local UI directory") }
        }
        try validateLocalRecoveryDirectory(socketDirectory)
        path = socketDirectory.appendingPathComponent("s").path
        guard path.utf8.count < 104 else { throw CoreError("local_ui_unavailable", "State path is too long for local UI socket") }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else { throw CoreError("unsafe_state", "Unsafe local UI socket") }
            guard unlink(path) == 0 else { throw CoreError("local_ui_unavailable", "Cannot remove stale local UI socket") }
        } else if errno != ENOENT { throw CoreError("local_ui_unavailable", "Cannot inspect local UI socket") }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CoreError("local_ui_unavailable", "Cannot create local UI socket") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let name = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: name) }
        let listener = descriptor
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { close(descriptor); throw CoreError("local_ui_unavailable", "Cannot bind local UI socket") }
        do { identity = try LocalRecoverySocketIdentity(path: path) }
        catch { close(descriptor); throw error }
        guard chmod(path, 0o600) == 0, listen(descriptor, 4) == 0 else {
            close(descriptor); identity.removeIfUnchanged(path: path)
            throw CoreError("local_ui_unavailable", "Cannot protect local UI socket")
        }
        DispatchQueue.global(qos: .utility).async {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                var uid: uid_t = 0, gid: gid_t = 0, timeout = timeval(tv_sec: 2, tv_usec: 0)
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
                var data = Data(), bytes = [UInt8](repeating: 0, count: 256)
                while data.count < 256 && !data.contains(10) {
                    let count = read(client, &bytes, bytes.count)
                    if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count))
                }
                guard data == Data("{\"op\":\"open_changes\"}\n".utf8) else { close(client); continue }
                DispatchQueue.main.async {
                    openWindow()
                    let reply = Array("{\"opened\":true}\n".utf8)
                    _ = reply.withUnsafeBytes { send(client, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
                    close(client)
                }
            }
        }
    }
    deinit { close(descriptor); identity.removeIfUnchanged(path: path) }
}

@MainActor
final class LocalRecoveryWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private let broker: Broker
    private var window: NSWindow?
    private let table = NSTableView(), details = NSTextView(), status = NSTextField(labelWithString: "")
    private let since = NSTextField(), until = NSTextField(), action = NSPopUpButton()
    private let apply = NSButton(title: "Apply this batch", target: nil, action: nil)
    private var inventory: [JSON] = [], remaining: [String] = [], steps: [JSON] = [], reviewedIDs: [String] = [], appliedIDs: [String] = []
    private var busy = false
    private var reviewGate = NativeReviewGate()
    init(broker: Broker) { self.broker = broker; super.init() }
    private func button(_ title: String, _ selector: Selector) -> NSButton { NSButton(title: title, target: self, action: selector) }
    func open() {
        if window == nil { buildWindow() }
        NSApp.setActivationPolicy(.regular); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if inventory.isEmpty { refresh() }
    }
    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Calendar integration — stored changes and rollback"; w.center(); w.isReleasedWhenClosed = false
        since.placeholderString = "Since (ISO8601, optional)"; until.placeholderString = "Until (ISO8601, optional)"
        since.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        until.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        since.delegate = self; until.delegate = self; w.delegate = self
        action.target = self; action.action = #selector(filtersChanged)
        action.addItems(withTitles: ["Modify and delete", "Modify", "Delete"])
        let filters = NSStackView(views: [since, until, action, button("Refresh matching", #selector(refresh))]); filters.orientation = .horizontal
        let controls = NSStackView(views: [button("Select all matching", #selector(selectAll)), button("Select eligible", #selector(selectEligible)), button("Show stored details", #selector(showDetails)), button("Review selected", #selector(reviewSelected)), apply, button("Cancel review", #selector(cancelReview))]); controls.orientation = .horizontal
        apply.target = self; apply.action = #selector(applyBatch); apply.isEnabled = false
        for (id, title, width) in [("created", "Captured", 185.0), ("action", "Action", 75.0), ("title", "Stored event", 380.0), ("eligibility", "Recovery", 350.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = true
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.heightAnchor.constraint(equalToConstant: 240).isActive = true
        details.isEditable = false; details.isSelectable = true; details.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let review = NSScrollView(); review.documentView = details; review.hasVerticalScroller = true
        details.autoresizingMask = [.width]; details.textContainer?.widthTracksTextView = true
        status.maximumNumberOfLines = 3
        let introduction = NSTextField(wrappingLabelWithString: "Changes captured by this integration. Event details expire after the configured retention period (default 5 days); unresolved writes retain their evidence. Rollback uses exact native previews, stale checks and durable execution records.")
        let stack = NSStackView(views: [introduction, filters, controls, status, list, review]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; w.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor, constant: -16)])
        for view in [introduction, filters, controls, status, list, review] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        window = w
    }
    private func call(_ op: String, _ arguments: [String: JSON]) async -> JSON {
        let broker = broker
        return await Task.detached { broker.handle(.object(["op": .string(op), "arguments": .object(arguments)])) }.value
    }
    private func invalidateReview() {
        reviewGate.invalidate(); steps = []; reviewedIDs = []; apply.isEnabled = false
    }
    private func show(_ value: JSON, exactReview: Bool = false) {
        if !exactReview { invalidateReview() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        details.string = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "Unable to display review"
        details.scrollToBeginningOfDocument(nil)
    }
    @objc private func refresh() {
        guard !busy else { return }; cancelReview(); busy = true
        var filters: [String: JSON] = ["limit": .int(100), "include_expired": .bool(true)]
        if !since.stringValue.isEmpty { filters["since"] = .string(since.stringValue) }
        if !until.stringValue.isEmpty { filters["until"] = .string(until.stringValue) }
        if action.indexOfSelectedItem > 0 { filters["action"] = .string(action.indexOfSelectedItem == 1 ? "modify" : "delete") }
        status.stringValue = "Loading complete matching inventory…"
        Task {
            var rows: [JSON] = [], args = filters
            while true {
                let response = await call("list_changes", args)
                if response["error"] != .null { show(response); busy = false; status.stringValue = "Unable to load stored changes"; return }
                rows += response["result"]["changes"].array ?? []
                guard let cursor = response["result"]["next_cursor"].string else { break }; args["cursor"] = .string(cursor)
            }
            inventory = rows; table.reloadData(); busy = false
            let eligible = rows.filter { $0["recovery_eligible"] == .bool(true) }.count
            status.stringValue = "Loaded all \(rows.count) matching changes: \(eligible) eligible; \(rows.count - eligible) blocked or already rolled back. Select rows to inspect or review."
        }
    }
    @objc private func selectAll() { guard !busy else { return }; table.selectRowIndexes(IndexSet(integersIn: 0..<inventory.count), byExtendingSelection: false); status.stringValue = "Selected all \(inventory.count) matching changes, including blocked entries. Review reports blocked selections." }
    @objc private func selectEligible() { guard !busy else { return }; table.selectRowIndexes(IndexSet(inventory.indices.filter { inventory[$0]["recovery_eligible"] == .bool(true) }), byExtendingSelection: false); status.stringValue = "Selected \(table.numberOfSelectedRows) eligible changes out of \(inventory.count) matching. Blocked entries are excluded explicitly." }
    @objc private func showDetails() {
        guard !busy, table.selectedRow >= 0 else { return }; invalidateReview(); let generation = reviewGate.generation; let id = inventory[table.selectedRow]["change_id"]
        Task { let response = await call("get_stored_change", ["change_id": id]); guard generation == reviewGate.generation else { return }; show(response) }
    }
    @objc private func reviewSelected() {
        guard !busy else { return }; invalidateReview()
        let selected = table.selectedRowIndexes.map { inventory[$0] }
        guard !selected.isEmpty else { status.stringValue = "Select changes first"; return }
        let blocked = selected.filter { $0["recovery_eligible"] != .bool(true) }
        guard blocked.isEmpty else { show(.object(["blocked_changes": .array(blocked)])); status.stringValue = "\(blocked.count) selected changes are blocked. Deselect them or explicitly Select eligible."; return }
        remaining = selected.compactMap { $0["change_id"].string }; appliedIDs = []; prepareNextBatch()
    }
    private func prepareNextBatch() {
        guard !remaining.isEmpty else { status.stringValue = "Completed \(appliedIDs.count) selected source changes."; apply.isEnabled = false; return }
        invalidateReview(); let generation = reviewGate.generation
        busy = true; apply.isEnabled = false; let batch = Array(remaining.prefix(25))
        Task {
            let response = await call("preflight_rollback", ["change_ids": .array(batch.map(JSON.string))]); busy = false
            guard generation == reviewGate.generation else { return }
            guard response["error"] == .null, let values = response["result"]["steps"].array else { show(response); status.stringValue = "Batch could not be prepared. \(remaining.count) source changes remain unattempted."; steps = []; return }
            steps = values; reviewedIDs = batch
            show(.object(["selected_total": .int(appliedIDs.count + remaining.count), "already_applied_source_ids": .array(appliedIDs.map(JSON.string)), "this_batch_source_ids": .array(batch.map(JSON.string)), "remaining_after_batch": .int(remaining.count - batch.count), "exact_review": response["result"]]), exactReview: true)
            guard reviewGate.displayReview(generation: generation) else { invalidateReview(); return }
            status.stringValue = "Review this batch: \(batch.count) source changes in \(values.count) event steps. \(appliedIDs.count) already applied; \(remaining.count - batch.count) queued. Each event step commits separately."
            apply.title = "Apply this batch (\(batch.count))"; apply.isEnabled = true
        }
    }
    @objc private func applyBatch() {
        guard !busy, !steps.isEmpty, reviewGate.canApply else { return }; let generation = reviewGate.generation; busy = true; apply.isEnabled = false
        let captured = steps, broker = broker
        Task {
            var outcomes: [JSON] = []
            for (index, step) in captured.enumerated() {
                guard generation == reviewGate.generation else { busy = false; status.stringValue = "Review closed or changed; remaining steps were not attempted."; return }
                let response = await Task.detached { broker.commitReviewedRollback(step["preview"]) }.value
                outcomes.append(.object(["source_change_ids": step["preview"]["envelope"]["rollback"]["source_change_ids"], "response": response]))
                if response["result"]["state"] != .string("applied") {
                    let unattempted = captured.dropFirst(index + 1).map { $0["preview"]["envelope"]["rollback"]["source_change_ids"] }
                    show(.object(["attempted_step_outcomes": .array(outcomes), "unattempted_steps": .array(unattempted), "remaining_source_ids": .array(remaining.map(JSON.string))]))
                    status.stringValue = "Stopped after step \(index + 1): failed or unknown. Applied steps remain applied. Inspect outcomes before preparing another batch."
                    steps = []; busy = false; return
                }
                let sources = step["preview"]["envelope"]["rollback"]["source_change_ids"].array!.compactMap(\.string)
                appliedIDs += sources; remaining.removeAll { sources.contains($0) }
            }
            steps = []; busy = false
            guard generation == reviewGate.generation else { return }
            if remaining.isEmpty { show(.object(["applied_source_ids": .array(appliedIDs.map(JSON.string)), "outcomes": .array(outcomes)])); status.stringValue = "Completed rollback of all \(appliedIDs.count) selected source changes." }
            else { prepareNextBatch() }
        }
    }
    @objc private func cancelReview() {
        invalidateReview()
        if busy { status.stringValue = "Review cancelled. An in-flight event step may finish; no additional steps will be attempted." }
        else { remaining = []; status.stringValue = "Review cancelled. No additional rollback will be attempted." }
    }
    @objc private func filtersChanged() { invalidateReview(); status.stringValue = "Filters changed. Refresh matching before selecting a new inventory." }
    func controlTextDidChange(_ notification: Notification) { filtersChanged() }
    func tableViewSelectionDidChange(_ notification: Notification) { invalidateReview() }
    func windowWillClose(_ notification: Notification) { invalidateReview() }
    func numberOfRows(in tableView: NSTableView) -> Int { inventory.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = inventory[row], text: String
        switch tableColumn?.identifier.rawValue {
        case "created": text = item["created_at"].string ?? ""
        case "action": text = item["action"].string ?? ""
        case "title": text = item["title"].string ?? (item["details_expired"] == .bool(true) ? "Details expired" : "Stored change")
        default: text = item["recovery_eligible"] == .bool(true) ? "Eligible" : item["recovery_reason"].string ?? "Blocked"
        }
        return NSTextField(labelWithString: text)
    }
}
