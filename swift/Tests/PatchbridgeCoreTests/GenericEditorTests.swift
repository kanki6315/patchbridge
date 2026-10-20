import XCTest
@testable import PatchbridgeCore

final class GenericEditorTests: XCTestCase {
    struct Fixture: Decodable { let catalog: EditorCatalog; let snapshot: PresetSnapshot }
    func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("tests/fixtures/qc-editor.json")))
    }
    func editor(_ fixture: Fixture) throws -> GenericEditor {
        let model = GenericEditor()
        try model.load(snapshot: fixture.snapshot, catalog: fixture.catalog, session: "session", connection: "connection", revision: 3, operations: ["set_parameter", "save"])
        return model
    }
    func modified(_ snapshot: PresetSnapshot, gain: Double) throws -> PresetSnapshot {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        var blocks = object["blocks"] as! [[String: Any]]
        let i = blocks.firstIndex { $0["id"] as? String == "0:1" }!
        var scenes = blocks[i]["scenes"] as! [String: [String: Any]]
        var parameters = scenes["F"]!["parameters"] as! [String: Any]
        parameters["0"] = gain; scenes["F"]!["parameters"] = parameters
        blocks[i]["scenes"] = scenes; object["blocks"] = blocks
        return try JSONDecoder().decode(PresetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testCapturedPresetUsesRealBlockAndParameterIDs() throws {
        let f = try fixture(); let model = try editor(f)
        XCTAssertEqual(model.snapshot?.blocks.count, 16)
        XCTAssertEqual(model.snapshot?.scene, "F")
        XCTAssertEqual(model.snapshot?.scene_labels?[5], "RHYTHM")
        XCTAssertEqual(model.snapshot?.scene_colors?[5], 4294930432)
        XCTAssertEqual(model.catalog?.models[f.snapshot.blocks.first { $0.id == "0:1" }!.model_id]?.category, "Compressor")
        XCTAssertTrue(model.supports("save"))
        XCTAssertFalse(model.supports("select_scene"))
        XCTAssertEqual(model.control(blockID: "0:1", parameterID: "0")?.name, "THRESHOLD")
        XCTAssertNil(model.readOnlyReason(blockID: "0:1", parameterID: "0"))
        XCTAssertNotNil(model.readOnlyReason(blockID: "0:3", parameterID: "0")) // Myth gain has no declared skew.
        XCTAssertNotNil(model.readOnlyReason(blockID: "unknown", parameterID: "0"))
    }
    func testDeclaredConversionRoundTripsAndRejectsOutOfRange() throws {
        let model = try editor(fixture())
        let control = try XCTUnwrap(model.control(blockID: "0:1", parameterID: "0"))
        XCTAssertEqual(control.displayValue(.number(0)), -60)
        XCTAssertEqual(control.displayValue(.number(1)), 12)
        let wire = try XCTUnwrap(control.wireValue(display: -24))
        XCTAssertEqual(control.displayValue(wire), -24)
        XCTAssertNil(control.wireValue(display: 100))
        XCTAssertNil(control.displayValue(.boolean(true)))
        XCTAssertNil(control.wireValue(display: .nan))
    }
    func testPendingEditDoesNotMutateConfirmedValueAndRejectRestores() throws {
        let model = try editor(fixture()); let original = model.value(blockID: "0:1", parameterID: "0")
        let edit = try model.propose(blockID: "0:1", parameterID: "0", value: .number(0.5))
        XCTAssertEqual(edit.command["scene"] as? String, "F")
        XCTAssertEqual(edit.command["revision"] as? Int, 3)
        XCTAssertEqual(model.value(blockID: "0:1", parameterID: "0"), original)
        XCTAssertThrowsError(try model.propose(blockID: "0:1", parameterID: "0", value: .number(0.6)))
        model.reject(id: edit.id, message: "Device rejected edit")
        XCTAssertNil(model.pending); XCTAssertEqual(model.value(blockID: "0:1", parameterID: "0"), original)
    }
    func testReadbackAndReconnectRejectOldEdits() throws {
        let f = try fixture(); let model = try editor(f)
        let edit = try model.propose(blockID: "0:1", parameterID: "0", value: .number(0.5))
        let updated = try modified(f.snapshot, gain: 0.49)
        XCTAssertThrowsError(try model.confirm(id: edit.id, snapshot: updated, session: "old", connection: "connection", revision: 4))
        try model.confirm(id: edit.id, snapshot: updated, session: "session", connection: "connection", revision: 4)
        XCTAssertEqual(model.value(blockID: "0:1", parameterID: "0"), .number(0.49))
        model.disconnect()
        XCTAssertThrowsError(try model.confirm(id: edit.id, snapshot: updated, session: "session", connection: "connection", revision: 5))
        XCTAssertNil(model.snapshot)
    }
    func testMissingCapabilitiesPreventsEdits() throws {
        let f = try fixture(); let model = GenericEditor()
        try model.load(snapshot: f.snapshot, catalog: f.catalog, session: "s", connection: "c", revision: 0, operations: [])
        XCTAssertThrowsError(try model.propose(blockID: "0:1", parameterID: "0", value: .number(0.5)))
    }
}

extension GenericEditorTests {
    func testExplicitNonlinearMappingAndNamedOptions() throws {
        let model = try editor(fixture())
        let ratio = try XCTUnwrap(model.control(blockID: "0:1", parameterID: "1"))
        let wire = try XCTUnwrap(ratio.wireValue(display: 4))
        XCTAssertEqual(try XCTUnwrap(ratio.displayValue(wire)), 4, accuracy: 1e-9)
        let mode = try XCTUnwrap(model.control(blockID: "2:6", parameterID: "1"))
        XCTAssertEqual(mode.options?.map(\.label), ["Chorus", "Vibe"])
        XCTAssertFalse(mode.accepts(.number(0.5)))
        XCTAssertTrue(mode.accepts(.number(1)))
    }
    func testExternalStateCancelsPendingEdit() throws {
        let f = try fixture(); let model = try editor(f)
        let edit = try model.propose(blockID: "0:1", parameterID: "0", value: .number(0.5))
        try model.refresh(modified(f.snapshot, gain: 0.3), session: "session", connection: "connection", revision: 4)
        XCTAssertNil(model.pending)
        XCTAssertThrowsError(try model.confirm(id: edit.id, snapshot: f.snapshot, session: "session", connection: "connection", revision: 5))
        XCTAssertEqual(model.value(blockID: "0:1", parameterID: "0"), .number(0.3))
    }
    func testSaveRequiresCleanReadbackAndCatalogMismatchFailsClosed() throws {
        let f = try fixture(); let model = try editor(f)
        let save = try model.proposeSave()
        XCTAssertEqual(save.command["operation"] as? String, "save")
        XCTAssertThrowsError(try model.confirm(id: save.id, snapshot: f.snapshot, session: "session", connection: "connection", revision: 4))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.snapshot)) as! [String: Any]
        object["dirty"] = false
        let clean = try JSONDecoder().decode(PresetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        try model.confirm(id: save.id, snapshot: clean, session: "session", connection: "connection", revision: 4)
        XCTAssertEqual(model.snapshot?.dirty, false)
        object["catalog_id"] = "old-catalog"
        let mismatch = try JSONDecoder().decode(PresetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try model.load(snapshot: mismatch, catalog: f.catalog, session: "new", connection: "c", revision: 0, operations: ["set_parameter"]))
        XCTAssertNil(model.snapshot)
        XCTAssertThrowsError(try model.proposeSave())
    }
}

extension GenericEditorTests {
    func testUnchangedRefreshPreservesPendingButConflictingRevisionFails() throws {
        let f = try fixture(); let model = try editor(f)
        let edit = try model.propose(blockID: "0:1", parameterID: "0", value: .number(0.5))
        try model.refresh(f.snapshot, session: "session", connection: "connection", revision: 3)
        XCTAssertEqual(model.pending?.id, edit.id)
        XCTAssertThrowsError(try model.refresh(modified(f.snapshot, gain: 0.2), session: "session", connection: "connection", revision: 3))
    }
}

extension GenericEditorTests {
    func testCapturedStructureVariantsAreRejectedOnLoadAndRefresh() throws {
        let f = try fixture()
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.snapshot)) as! [String: Any]
        for variant in ["scene", "position", "duplicatePosition", "duplicateID", "emptyModel", "unknownSceneKey"] {
            var object = original
            var blocks = object["blocks"] as! [[String: Any]]
            switch variant {
            case "scene": object["scene"] = "Z"
            case "position": blocks[0]["position"] = [4, 8]
            case "duplicatePosition": blocks[0]["position"] = blocks[1]["position"]
            case "duplicateID": blocks[0]["id"] = blocks[1]["id"]
            case "emptyModel": blocks[0]["model_id"] = ""
            default: blocks[0]["scenes"] = ["Z": ["parameters": [:]]] as [String: Any]
            }
            object["blocks"] = blocks
            let invalid = try JSONDecoder().decode(PresetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            let model = try editor(f)
            XCTAssertThrowsError(try model.refresh(invalid, session: "session", connection: "connection", revision: 4), variant)
            XCTAssertEqual(model.snapshot, f.snapshot)
            XCTAssertThrowsError(try model.load(snapshot: invalid, catalog: f.catalog, session: "s", connection: "c", revision: 0, operations: ["set_parameter"]), variant)
            XCTAssertNil(model.snapshot)
        }
    }
    func testCapturedUnknownModelMissingSceneAndTypedValuesRemainReadOnly() throws {
        let f = try fixture()
        for variant in ["unknownModel", "missingScene", "text", "boolean", "null", "permissions"] {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.snapshot)) as! [String: Any]
            var blocks = object["blocks"] as! [[String: Any]]
            let index = blocks.firstIndex { $0["id"] as? String == "0:1" }!
            var scenes = blocks[index]["scenes"] as! [String: [String: Any]]
            var parameters = scenes["F"]!["parameters"] as! [String: Any]
            switch variant {
            case "unknownModel": blocks[index]["model_id"] = "unknown"
            case "missingScene": scenes.removeValue(forKey: "F")
            case "text": parameters["0"] = "unresolved"
            case "boolean": parameters["0"] = true
            case "null": parameters["0"] = NSNull()
            default: blocks[index].removeValue(forKey: "editable_parameters")
            }
            if scenes["F"] != nil { scenes["F"]!["parameters"] = parameters }
            blocks[index]["scenes"] = scenes; object["blocks"] = blocks
            let state = try JSONDecoder().decode(PresetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            let model = GenericEditor()
            try model.load(snapshot: state, catalog: f.catalog, session: "s", connection: "c", revision: 0, operations: ["set_parameter"])
            XCTAssertNotNil(model.readOnlyReason(blockID: "0:1", parameterID: "0"), variant)
            XCTAssertThrowsError(try model.propose(blockID: "0:1", parameterID: "0", value: .number(0.5)), variant)
        }
    }
    func testCorruptEnumerationMetadataCannotEnableWrites() throws {
        let base: [String: Any] = ["kind": "enum", "encoding": "qc_normalized", "name": "Mode", "unit": "", "editable": true]
        for options in [[("Off", -1.0), ("On", 1.0)], [("Off", 0.0), ("On", 0.0)], [("", 0.0), ("On", 1.0)], [("Only", 1.0)]] {
            var object = base; object["options"] = options.map { ["label": $0.0, "value": $0.1] }
            let control = try JSONDecoder().decode(ParameterControl.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertFalse(control.accepts(.number(options[0].1)))
        }
    }
}
