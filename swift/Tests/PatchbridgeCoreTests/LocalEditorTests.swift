import XCTest
@testable import PatchbridgeCore

/// The Mac's own editor: the real coordinator, through `LocalEditorTransport`, on a bridge that
/// also serves a phone, against the simulated helper.
final class LocalEditorTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func helper() throws -> HelperClient {
        let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
        return try HelperClient(python: try XCTUnwrap(python), source: root.appendingPathComponent("src").path)
    }
    private func wait(_ coordinator: EditorCoordinator, timeout: TimeInterval = 10, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            coordinator.tick()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
    private func value(_ editor: GenericEditor, _ block: String, _ parameter: String) -> ParameterValue? {
        editor.value(blockID: block, parameterID: parameter)
    }

    func testMacEditorJoinsWithoutACodeAndSharesEditsWithAPhone() throws {
        let queue = DispatchQueue(label: "local-editor-test")
        let helper = try helper(), phone = TestPeripheral()
        let host = LiveBridgeBackend(peripheral: phone, makeHelper: { helper })
        try queue.sync { try host.start() }
        defer { queue.sync { host.stop() } }
        var transports = [UUID: LocalEditorTransport]()
        host.onLocalEvent = { id, event in DispatchQueue.main.async { transports[id]?.deliver(event) } }
        let transport = LocalEditorTransport(queue: queue, request: { host.localRequest($0, $1) }, left: { host.localLeft($0) })
        transports[transport.id] = transport
        let coordinator = EditorCoordinator(automaticPolling: false, phoneName: "Studio Mac", makeTransport: { transport })
        var changes = 0
        coordinator.onChange = { changes += 1 }

        coordinator.start()
        wait(coordinator) { coordinator.phase == .awaitingApproval }
        XCTAssertEqual(coordinator.phase, .awaitingApproval)
        // Approved by being on this Mac: no approval card, and the window lists no device.
        queue.sync {
            XCTAssertEqual(host.state?.0, .running)
            XCTAssertTrue(host.presentation.devices.isEmpty)
        }
        coordinator.authorize()
        wait(coordinator) { coordinator.phase == .ready }
        XCTAssertEqual(coordinator.phase, .ready)
        let snapshot = try XCTUnwrap(coordinator.editor.snapshot)
        let block = try XCTUnwrap(snapshot.blocks.first { block in
            coordinator.editor.visibleParameters(blockID: block.id).contains { coordinator.editor.readOnlyReason(blockID: block.id, parameterID: $0) == nil }
        })
        let parameter = try XCTUnwrap(coordinator.editor.visibleParameters(blockID: block.id).first { coordinator.editor.readOnlyReason(blockID: block.id, parameterID: $0) == nil })
        queue.sync { XCTAssertTrue(host.presentation.devices.isEmpty) }

        // A phone joins the same bridge and connects.
        let (token, session): (String, String) = try queue.sync {
            let token = try XCTUnwrap(phone.send("hello", fields: ["device_name": "Stage Phone", "state_notifications": true])["connection_id"] as? String)
            try host.approvePending()
            let session = try XCTUnwrap(phone.send("connect", token: token)["session_id"] as? String)
            XCTAssertEqual(host.presentation.connected.map(\.name), ["Stage Phone"])
            return (token, session)
        }

        // The Mac edits: the QC confirms it and the phone is told who changed it.
        let control = try XCTUnwrap(coordinator.editor.control(blockID: block.id, parameterID: parameter))
        let current = value(coordinator.editor, block.id, parameter)
        let candidates: [ParameterValue] = control.options.map { $0.map { .number($0.value) } }
            ?? [0.25, 0.75].compactMap { fraction in
                control.minimum.flatMap { low in control.maximum.flatMap { high in control.wireValue(display: low + (high - low) * fraction) } }
            }
        let target = try XCTUnwrap(candidates.first { $0 != current && control.acceptsEdit($0) })
        queue.sync { phone.notifications.removeAll() }
        try coordinator.edit(blockID: block.id, parameterID: parameter, value: target)
        wait(coordinator) { coordinator.editor.pending == nil && value(coordinator.editor, block.id, parameter) == target }
        XCTAssertEqual(value(coordinator.editor, block.id, parameter), target)
        XCTAssertNil(coordinator.error)
        queue.sync {
            let pushed = phone.notifications.last { $0.1["event"] as? String == "state_updated" }?.1
            XCTAssertEqual(pushed?["changed_by"] as? String, "Studio Mac")
        }

        // The phone saves; the Mac's editor gets the new state pushed, without asking.
        let revision = try XCTUnwrap(queue.sync { phone.send("snapshot", token: token, session: session)["revision"] as? Int })
        let saved = queue.sync {
            phone.send("save", token: token, session: session, fields: ["revision": revision, "preset_id": snapshot.preset_id, "scene": snapshot.scene])
        }
        XCTAssertEqual(saved["status"] as? String, "confirmed")
        wait(coordinator) { coordinator.editor.snapshot?.dirty == false }
        XCTAssertEqual(coordinator.editor.snapshot?.dirty, false)

        // Stopping the bridge ends the Mac's session; nothing is replayed.
        queue.sync { host.stop() }
        coordinator.refresh()
        wait(coordinator) { coordinator.phase == .failed }
        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertGreaterThan(changes, 0)
    }

    func testLeavingFreesTheMacEditorsSlot() throws {
        let queue = DispatchQueue(label: "local-editor-test")
        let helper = try helper()
        let host = LiveBridgeBackend(peripheral: TestPeripheral(), makeHelper: { helper })
        try queue.sync { try host.start() }
        defer { queue.sync { host.stop() } }
        let ids = (0..<LiveBridgeBackend.deviceLimit).map { _ in UUID() }
        func hello(_ id: UUID) -> [String: Any]? {
            queue.sync { host.localRequest(id, ["version": 1, "id": UUID().uuidString, "operation": "hello", "device_name": "Mac"]) }
        }
        for id in ids { XCTAssertNotNil(hello(id)?["connection_id"]) }
        let extra = UUID()
        XCTAssertEqual((hello(extra)?["error"] as? [String: Any])?["code"] as? String, "bridge_full")
        queue.sync { host.localLeft(extra); host.localLeft(ids[0]) }
        XCTAssertNotNil(hello(extra)?["connection_id"])
        queue.sync { host.stop() }
        XCTAssertNil(hello(UUID())) // A stopped bridge reports nothing to the editor, which ends it.
    }

    func testSimulationServesTheMacEditor() throws {
        let backend = BundledOfflineBackend(makeHelper: { try self.helper() })
        try backend.start(); defer { backend.stop() }
        let queue = DispatchQueue(label: "local-editor-test")
        let transport = LocalEditorTransport(queue: queue, request: { backend.localRequest($0, $1) }, left: { backend.localLeft($0) })
        let coordinator = EditorCoordinator(automaticPolling: false, phoneName: "Studio Mac", makeTransport: { transport })
        coordinator.start()
        wait(coordinator) { coordinator.phase == .awaitingApproval }
        coordinator.authorize()
        wait(coordinator) { coordinator.phase == .ready }
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertTrue(backend.presentation.devices.isEmpty) // The simulation steps never act for it.
        coordinator.disconnect()
    }
}
