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
        // Myth gain declares no skew; hardware calibration showed such controls are linear.
        XCTAssertNil(model.readOnlyReason(blockID: "0:3", parameterID: "0"))
        XCTAssertEqual(try XCTUnwrap(model.control(blockID: "0:3", parameterID: "0")?.displayValue(.number(0.25))), 2.5, accuracy: 1e-9)
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
    func testDeclaredLookupTableInterpolatesBothWays() throws {
        func control(_ points: String, editable: Bool = true) throws -> ParameterControl {
            try JSONDecoder().decode(ParameterControl.self, from: Data("""
            {"kind":"number","encoding":"qc_normalized","name":"LO FREQ","unit":"Hz","editable":\(editable),
             "minimum":20,"maximum":200,"mapping":"table","points":\(points)}
            """.utf8))
        }
        let frequency = try control("[[0,20],[0.5,60],[1,200]]")
        XCTAssertEqual(try XCTUnwrap(frequency.displayValue(.number(0.25))), 40, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(frequency.displayValue(.number(0.75))), 130, accuracy: 1e-9)
        for display in [20.0, 40, 60, 130, 200] {
            let wire = try XCTUnwrap(frequency.wireValue(display: display))
            XCTAssertEqual(try XCTUnwrap(frequency.displayValue(wire)), display, accuracy: 1e-9)
        }
        XCTAssertNil(frequency.wireValue(display: 19)); XCTAssertNil(frequency.wireValue(display: 201))
        XCTAssertNil(frequency.displayValue(.number(1.01)))
        XCTAssertNil(try control("[[0,20],[0.5,60],[1,200]]", editable: false).wireValue(display: 60))
        for corrupt in ["[[0,20],[0.5,10],[1,200]]", "[[0,20],[1,150]]", "[[0.1,20],[1,200]]", "[[0,20,1],[1,200]]", "[]"] {
            let bad = try control(corrupt)
            XCTAssertNil(bad.displayValue(.number(0.5)), corrupt)
            XCTAssertNil(bad.wireValue(display: 60), corrupt)
            XCTAssertFalse(bad.accepts(.number(0.5)), corrupt)
        }
    }
    func testConditionalControlIsReadOnlyWhileItsSwitchIsInTheOtherPosition() throws {
        func editor(sync: Double) throws -> GenericEditor {
            let json = """
            {"catalog": {"id": "c", "metadata_version": 1, "models": {"9": {"name": "Simple Delay", "parameters": {
               "0": {"control": {"kind": "enum", "encoding": "qc_normalized", "name": "SYNC", "unit": "", "editable": true,
                     "options": [{"label": "Off", "value": 0}, {"label": "On", "value": 1}]}},
               "1": {"control": {"kind": "number", "encoding": "qc_normalized", "name": "SYNC NOTE", "unit": "", "editable": true,
                     "minimum": 0, "maximum": 1, "mapping": "power", "exponent": 1, "active_when": {"parameter": "0", "values": [1]}}},
               "2": {"control": {"kind": "number", "encoding": "qc_normalized", "name": "DELAY TIME", "unit": "ms", "editable": true,
                     "minimum": 0, "maximum": 1, "mapping": "power", "exponent": 1, "active_when": {"parameter": "0", "values": [0]}}}}}}},
             "snapshot": {"preset_id": "p", "catalog_id": "c", "name": "Test", "scene": "A", "dirty": false,
               "blocks": [{"id": "0:0", "model_id": "9", "position": [0, 0], "editable_parameters": ["0", "1", "2"],
                 "scenes": {"A": {"parameters": {"0": \(sync), "1": 0.25, "2": 0.5}}}}]}}
            """
            let f = try JSONDecoder().decode(Fixture.self, from: Data(json.utf8))
            return try self.editor(f)
        }
        let free = try editor(sync: 0)
        XCTAssertEqual(free.readOnlyReason(blockID: "0:0", parameterID: "1"), "Inactive while SYNC is Off.")
        XCTAssertNil(free.readOnlyReason(blockID: "0:0", parameterID: "2"))
        XCTAssertThrowsError(try free.propose(blockID: "0:0", parameterID: "1", value: .number(0.5)))
        let synced = try editor(sync: 1)
        XCTAssertNil(synced.readOnlyReason(blockID: "0:0", parameterID: "1"))
        XCTAssertEqual(synced.readOnlyReason(blockID: "0:0", parameterID: "2"), "Inactive while SYNC is On.")
        XCTAssertNil(synced.readOnlyReason(blockID: "0:0", parameterID: "0"))
    }
    func testConditionalControlFollowsStepsAndItsSwitchsOwnState() throws {
        func editor(link: Double, adjust: Double) throws -> GenericEditor {
            let json = """
            {"catalog": {"id": "c", "metadata_version": 1, "models": {"9": {"name": "Phase Doctor", "parameters": {
               "0": {"control": {"kind": "enum", "encoding": "qc_normalized", "name": "STEREO LINK", "unit": "", "editable": true,
                     "options": [{"label": "Unlinked", "value": 0}, {"label": "Linked", "value": 1}]}},
               "1": {"control": {"kind": "enum", "encoding": "qc_normalized", "name": "ADJUST R", "unit": "", "editable": true,
                     "options": [{"label": "Bypass", "value": 0}, {"label": "90", "value": 0.5}, {"label": "180", "value": 1}],
                     "active_when": {"parameter": "0", "values": [0]}}},
               "2": {"control": {"kind": "number", "encoding": "qc_normalized", "name": "SHIFT R", "unit": "", "editable": true,
                     "minimum": 0, "maximum": 1, "mapping": "power", "exponent": 1, "active_when": {"parameter": "1", "values": [0.5, 1]}}}}}}},
             "snapshot": {"preset_id": "p", "catalog_id": "c", "name": "Test", "scene": "A", "dirty": false,
               "blocks": [{"id": "0:0", "model_id": "9", "position": [0, 0], "editable_parameters": ["0", "1", "2"],
                 "scenes": {"A": {"parameters": {"0": \(link), "1": \(adjust), "2": 0.25}}}}]}}
            """
            return try self.editor(try JSONDecoder().decode(Fixture.self, from: Data(json.utf8)))
        }
        XCTAssertNil(try editor(link: 0, adjust: 0.5).readOnlyReason(blockID: "0:0", parameterID: "2"))
        XCTAssertEqual(try editor(link: 0, adjust: 0).readOnlyReason(blockID: "0:0", parameterID: "2"), "Inactive while ADJUST R is Bypass.")
        XCTAssertEqual(try editor(link: 1, adjust: 1).readOnlyReason(blockID: "0:0", parameterID: "2"), "Inactive while ADJUST R is inactive.")
        XCTAssertEqual(try editor(link: 1, adjust: 1).readOnlyReason(blockID: "0:0", parameterID: "1"), "Inactive while STEREO LINK is Linked.")
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
    func testHiddenAndUndefinedParametersAreNotListed() throws {
        let f = try fixture(); let model = try editor(f)
        // Transpose shows only SEMITONES on the QC: MIX and PITCH COARSE/FINE are hidden, and 4 has no definition.
        XCTAssertEqual(model.visibleParameters(blockID: "0:4"), ["3"])
        XCTAssertEqual(model.control(blockID: "0:4", parameterID: "0")?.name, "MIX")
        XCTAssertEqual(model.readOnlyReason(blockID: "0:4", parameterID: "0"), "Hidden on the QC.")
        XCTAssertThrowsError(try model.propose(blockID: "0:4", parameterID: "0", value: .number(0.5)))
        XCTAssertNil(model.readOnlyReason(blockID: "0:4", parameterID: "3"))
        // The QC draws Opto Comp's gain reduction meter, so it stays listed, read-only.
        XCTAssertEqual(model.visibleParameters(blockID: "0:1"), ["0", "1", "2", "3", "4", "5", "6"])
        XCTAssertEqual(model.readOnlyReason(blockID: "0:1", parameterID: "6"), "Meter, not a control.")
        XCTAssertEqual(model.visibleParameters(blockID: "unknown"), [])
    }
    func testCaptureBlocksUseTheCaptureName() throws {
        let f = try fixture(); let model = try editor(f)
        let names = ["0:2": "OG TS808", "2:1": "Paul's MT16 7", "2:3": "Paul's MT16 6", "3:1": "Paul's MT16 7", "3:3": "Bogna Uber 1"]
        for (id, name) in names {
            XCTAssertEqual(model.blockName(blockID: id), name)
            XCTAssertEqual(model.modelName(blockID: id), "Eltron 30")
            // file_name is read for display only: never listed, never writable.
            XCTAssertFalse(model.visibleParameters(blockID: id).contains("5"))
            XCTAssertEqual(model.readOnlyReason(blockID: id, parameterID: "5"), "Hidden on the QC.")
            XCTAssertThrowsError(try model.propose(blockID: id, parameterID: "5", value: .text("0000OG TS808")))
        }
        XCTAssertEqual(model.blockName(blockID: "0:1"), "Opto Comp (M)")
        XCTAssertNil(model.captureName(blockID: "0:1"))
        XCTAssertNil(model.blockName(blockID: "unknown"))
    }
    func testCaptureNameFallsBackToTheModelName() throws {
        let f = try fixture()
        for value in [nil, "", "not a hash", String(repeating: "a", count: 64), String(repeating: "A", count: 64) + "Caps", 0.5] as [Any?] {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.snapshot)) as! [String: Any]
            var blocks = object["blocks"] as! [[String: Any]]
            let i = blocks.firstIndex { $0["id"] as? String == "0:2" }!
            var scenes = blocks[i]["scenes"] as! [String: [String: Any]]
            var parameters = scenes["F"]!["parameters"] as! [String: Any]
            parameters["5"] = value; scenes["F"]!["parameters"] = parameters
            blocks[i]["scenes"] = scenes; object["blocks"] = blocks
            let state = try JSONDecoder().decode(PresetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            let model = GenericEditor()
            try model.load(snapshot: state, catalog: f.catalog, session: "s", connection: "c", revision: 0, operations: [])
            XCTAssertEqual(model.blockName(blockID: "0:2"), "Eltron 30", "\(String(describing: value))")
        }
    }
    func testCaptureNameParsing() {
        let hash = "1e64c27a1335d9061530283b7c6b22c16f1a7abe0398ba36dfc77e6f462be2c2"
        XCTAssertEqual(GenericEditor.captureName(fileName: hash + "OG TS808"), "OG TS808")
        XCTAssertEqual(GenericEditor.captureName(fileName: hash + " Paul's MT16 7 "), "Paul's MT16 7")
        XCTAssertEqual(GenericEditor.captureName(fileName: hash + hash), hash)
        XCTAssertNil(GenericEditor.captureName(fileName: ""))
        XCTAssertNil(GenericEditor.captureName(fileName: "OG TS808"))
        XCTAssertNil(GenericEditor.captureName(fileName: hash))
        XCTAssertNil(GenericEditor.captureName(fileName: hash + "   "))
        XCTAssertNil(GenericEditor.captureName(fileName: String(hash.dropFirst()) + "OG TS808"))
        XCTAssertNil(GenericEditor.captureName(fileName: hash.uppercased() + "OG TS808"))
        XCTAssertNil(GenericEditor.captureName(fileName: "g" + hash.dropFirst() + "OG TS808"))
    }
    func testBlockWithoutCatalogModelListsEveryValueReadOnly() throws {
        let f = try fixture()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.snapshot)) as! [String: Any]
        var blocks = object["blocks"] as! [[String: Any]]
        let index = blocks.firstIndex { $0["id"] as? String == "0:4" }!
        blocks[index]["model_id"] = "unknown"; object["blocks"] = blocks
        let state = try JSONDecoder().decode(PresetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        let model = GenericEditor()
        try model.load(snapshot: state, catalog: f.catalog, session: "s", connection: "c", revision: 0, operations: ["set_parameter"])
        XCTAssertEqual(model.visibleParameters(blockID: "0:4"), ["0", "1", "2", "3", "4"])
        XCTAssertTrue(model.visibleParameters(blockID: "0:4").allSatisfy { model.readOnlyReason(blockID: "0:4", parameterID: $0) != nil })
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
