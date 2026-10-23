import XCTest
import CoreBluetooth
@testable import PatchbridgeCore

final class KeepAwakeTests: XCTestCase {
    private final class Ledger {
        var begun = 0, ended = 0
        var pending = [DispatchWorkItem]()
        func awake() -> KeepAwake {
            KeepAwake(grace: 90, begin: { self.begun += 1; return NSObject() }, end: { _ in self.ended += 1 },
                      after: { _, item in self.pending.append(item) })
        }
        func elapse() { let items = pending; pending.removeAll(); items.forEach { $0.perform() } }
    }
    func testHoldsOnceAndOutlastsTheLastPhoneByTheGrace() {
        let ledger = Ledger(), awake = ledger.awake()
        awake.hold(false); XCTAssertFalse(awake.holding); XCTAssertTrue(ledger.pending.isEmpty)
        awake.hold(true); awake.hold(true)
        XCTAssertTrue(awake.holding); XCTAssertEqual(ledger.begun, 1)
        awake.hold(false); awake.hold(false)
        XCTAssertTrue(awake.holding, "Kept through the grace so a dropped phone can come back")
        XCTAssertEqual(ledger.pending.count, 1)
        ledger.elapse()
        XCTAssertFalse(awake.holding); XCTAssertEqual(ledger.ended, 1)
    }
    func testAPhoneBackWithinTheGraceKeepsTheHold() {
        let ledger = Ledger(), awake = ledger.awake()
        awake.hold(true); awake.hold(false)
        let release = ledger.pending
        awake.hold(true)
        release.forEach { $0.perform() } // Even a release that already started.
        XCTAssertTrue(awake.holding); XCTAssertEqual(ledger.begun, 1); XCTAssertEqual(ledger.ended, 0)
        awake.stop(); XCTAssertFalse(awake.holding); XCTAssertEqual(ledger.ended, 1)
    }
    func testBridgeHoldsWhileAPhoneIsApprovedAndLetsGoOnStop() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path)
        let ledger = Ledger(), phone = TestPeripheral()
        let host = LiveBridgeBackend(peripheral: phone, makeHelper: { helper }, keepAwake: ledger.awake())
        try host.start()
        _ = phone.send("hello", fields: ["device_name": "Stage Phone"])
        XCTAssertFalse(host.keepAwake.holding, "Waiting for approval holds nothing")
        try host.approvePending(); XCTAssertTrue(host.keepAwake.holding)
        phone.leave(); XCTAssertTrue(host.keepAwake.holding); XCTAssertEqual(ledger.pending.count, 1)
        host.stop(); XCTAssertFalse(host.keepAwake.holding); XCTAssertEqual(ledger.ended, 1)
    }
    func testOnlyDropsThatMightRecoverAreTransient() {
        XCTAssertFalse(BLECentral.needsPairingReset(nil))
        XCTAssertFalse(BLECentral.needsPairingReset(NSError(domain: CBErrorDomain, code: CBError.Code.connectionTimeout.rawValue)))
        XCTAssertFalse(BLECentral.needsPairingReset(NSError(domain: CBErrorDomain, code: CBError.Code.peripheralDisconnected.rawValue)))
        XCTAssertTrue(BLECentral.needsPairingReset(NSError(domain: CBErrorDomain, code: CBError.Code.peerRemovedPairingInformation.rawValue)))
        XCTAssertTrue(BLECentral.needsPairingReset(NSError(domain: CBErrorDomain, code: CBError.Code.encryptionTimedOut.rawValue)))
    }
}
