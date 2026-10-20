import Foundation
import CoreBluetooth
import PatchbridgeCore

// Stable development UUIDs shared by the future iPhone central.
let serviceID = CBUUID(string: "79A90001-6E15-4C9F-AC53-147F7E639B01")
let commandID = CBUUID(string: "79A90002-6E15-4C9F-AC53-147F7E639B01")
let resultID = CBUUID(string: "79A90003-6E15-4C9F-AC53-147F7E639B01")

final class Peripheral: NSObject, CBPeripheralManagerDelegate {
    let queue = DispatchQueue(label: "patchbridge.bluetooth")
    var manager: CBPeripheralManager!
    let session: DeviceSession
    var central: CBCentral?
    var receiver = ChunkReceiver()
    var outgoing = [Data]()
    var transfer: UInt32 = 0
    let result = CBMutableCharacteristic(type: resultID, properties: [.notifyEncryptionRequired], value: nil, permissions: [.readEncryptionRequired])
    init(session: DeviceSession) {
        self.session = session
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: queue)
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { reset(); print("Bluetooth unavailable: \(peripheral.state.rawValue)"); return }
        let command = CBMutableCharacteristic(type: commandID, properties: [.write], value: nil, permissions: [.writeEncryptionRequired])
        let service = CBMutableService(type: serviceID, primary: true)
        service.characteristics = [command, result]
        peripheral.removeAllServices(); peripheral.add(service)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { print("Service error: \(error!)"); return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceID], CBAdvertisementDataLocalNameKey: session.macName])
        print("Advertising \(session.macName). Only simulated QC state is exposed.")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard self.central == nil else { return }
        self.central = central
        print("Phone \(central.identifier) subscribed. Code \(session.token.replacingOccurrences(of: "-", with: "").prefix(6).uppercased()). Type approve \(session.token) to authorize.")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if self.central?.identifier == central.identifier { reset() }
    }
    func reset() { central = nil; receiver.reset(); outgoing.removeAll(); session.revoke(); print("Connection reset; authorization cleared") }
    func status() {
        queue.async { print("Connection: \(self.central?.identifier.uuidString ?? "none"); approval token: \(self.session.token)") }
    }
    func approve(_ token: String) {
        queue.async {
            guard self.central != nil, token == self.session.token else { print("No matching pending connection"); return }
            self.session.approve(); print("Phone authorized for this connection")
        }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.characteristic.uuid == commandID, request.offset == 0,
                  central?.identifier == request.central.identifier, let bytes = request.value else {
                peripheral.respond(to: request, withResult: .writeNotPermitted); continue
            }
            // One outstanding response; phone must consume it before another command.
            guard outgoing.isEmpty else { peripheral.respond(to: request, withResult: .insufficientResources); continue }
            do {
                if let message = try receiver.receive(bytes) {
                    guard let object = try JSONSerialization.jsonObject(with: message) as? [String: Any], object["version"] as? Int == 1 else { throw BridgeFailure.protocolError }
                    let response: [String: Any]
                    do { response = try session.handle(object) }
                    catch { response = ["version": 1, "id": object["id"] ?? NSNull(), "connection_id": session.token, "status": "error", "error": String(describing: error)] }
                    let encoded = try JSONSerialization.data(withJSONObject: response)
                    transfer &+= 1
                    outgoing = try Chunks.split(encoded, limit: min(request.central.maximumUpdateValueLength, 512), transfer: transfer)
                    drain()
                }
                peripheral.respond(to: request, withResult: .success)
            } catch {
                receiver.reset(); peripheral.respond(to: request, withResult: .unlikelyError)
            }
        }
    }
    func drain() {
        guard let central else { return }
        while let bytes = outgoing.first {
            guard manager.updateValue(bytes, for: result, onSubscribedCentrals: [central]) else { return }
            outgoing.removeFirst()
        }
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { drain() }
}

let args = CommandLine.arguments
if args.count < 4 {
    print("Usage: bridge-demo <python-path> <repo-src-path> <--self-test|--ble>")
    exit(2)
}
do {
    let helper = try HelperClient(python: args[1], source: args[2])
    if args[3] == "--self-test" {
        let session = DeviceSession(helper: helper)
        let hello = try session.handle(["version": 1, "id": "hello", "operation": "hello"])
        session.approve()
        let connect = try session.handle(["version": 1, "id": "connect", "operation": "connect", "connection_id": hello["connection_id"]!])
        let state = (connect["result"] as! [String: Any])["state"] as! [String: Any]
        let edit: [String: Any] = ["version": 1, "id": "edit", "operation": "set_parameter", "connection_id": session.token,
            "session_id": connect["session_id"]!, "revision": connect["revision"]!,
            "preset_id": state["preset_id"]!, "scene": state["scene"]!,
            "payload": ["block_id": "amp-1", "parameter_id": "gain", "value": 7.0]]
        let data = try JSONSerialization.data(withJSONObject: edit)
        var receiver = ChunkReceiver()
        var decoded: Data?
        for chunk in try Chunks.split(data, limit: 20, transfer: 1) { decoded = try receiver.receive(chunk) }
        let response = try session.handle(JSONSerialization.jsonObject(with: decoded!) as! [String: Any])
        guard response["status"] as? String == "confirmed" else { throw BridgeFailure.protocolError }
        print("PASS: Swift → chunked message → authorized bridge → Python simulator → confirmed edit")
        helper.stop()
    } else if args[3] == "--ble" {
        let peripheral = Peripheral(session: DeviceSession(helper: helper))
        DispatchQueue.global().async {
            while let line = readLine() {
                if line == "status" { peripheral.status() }
                if line.hasPrefix("approve ") { peripheral.approve(String(line.dropFirst(8))) }
                if line == "quit" { helper.stop(); exit(0) }
            }
            helper.stop(); exit(0)
        }
        withExtendedLifetime(peripheral) { RunLoop.main.run() }
    } else { helper.stop(); exit(2) }
} catch { fputs("Bridge failed: \(error)\n", stderr); exit(1) }
