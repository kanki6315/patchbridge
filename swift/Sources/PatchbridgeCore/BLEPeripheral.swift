#if os(macOS)
import Foundation
import CoreBluetooth

/// All callbacks and methods run on the host's serial worker queue.
protocol BridgePeripheral: AnyObject {
    var onMessage: (([String: Any]) -> [String: Any])? { get set }
    var onDisconnect: (() -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    func start(name: String)
    func resetConnection()
    func stop()
}

final class BLEPeripheral: NSObject, BridgePeripheral, CBPeripheralManagerDelegate {
    var onMessage: (([String: Any]) -> [String: Any])?
    var onDisconnect: (() -> Void)?
    var onStatus: ((String) -> Void)?
    private let queue: DispatchQueue
    private var manager: CBPeripheralManager?
    private var name = "Mac"
    private var central: CBCentral?
    private var receiver = ChunkReceiver()
    private var outgoing = [Data]()
    private var outgoingIndex = 0
    private var transfer: UInt32 = 0
    private var result: CBMutableCharacteristic?
    private static let serviceID = CBUUID(string: "79A90001-6E15-4C9F-AC53-147F7E639B01")
    private static let commandID = CBUUID(string: "79A90002-6E15-4C9F-AC53-147F7E639B01")
    private static let resultID = CBUUID(string: "79A90003-6E15-4C9F-AC53-147F7E639B01")
    init(queue: DispatchQueue) { self.queue = queue; super.init() }
    func start(name: String) {
        stop(); self.name = name
        manager = CBPeripheralManager(delegate: self, queue: queue)
    }
    func stop() {
        manager?.delegate = nil; manager?.stopAdvertising(); manager?.removeAllServices(); manager = nil
        clear(); result = nil
    }
    private func clear() { central = nil; receiver.reset(); outgoing.removeAll(); outgoingIndex = 0 }
    func resetConnection() {
        clear()
        // Removing the service invalidates the phone's characteristics; fresh discovery is required.
        if let manager, manager.state == .poweredOn { installService(manager) }
    }
    private func installService(_ manager: CBPeripheralManager) {
        manager.stopAdvertising(); manager.removeAllServices()
        let result = CBMutableCharacteristic(type: Self.resultID, properties: [.notifyEncryptionRequired], value: nil, permissions: [.readEncryptionRequired])
        self.result = result
        let command = CBMutableCharacteristic(type: Self.commandID, properties: [.write], value: nil, permissions: [.writeEncryptionRequired])
        let service = CBMutableService(type: Self.serviceID, primary: true)
        service.characteristics = [command, result]; manager.add(service)
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        clear(); onDisconnect?()
        if peripheral.state == .poweredOn { installService(peripheral) }
        else {
            onStatus?(peripheral.state == .unauthorized ? "Allow Bluetooth access for Patchbridge in System Settings."
                : peripheral.state == .poweredOff ? "Bluetooth is off. Turn it on to connect your iPhone."
                : "Bluetooth is unavailable. Check System Settings or restart the bridge.")
        }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral === manager else { return }
        guard error == nil else { onStatus?("Bluetooth service couldn’t start. Restart the bridge."); return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID], CBAdvertisementDataLocalNameKey: name])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral === manager else { return }
        onStatus?(error == nil ? "Open Patchbridge on your iPhone and choose this Mac. Connect the QC over USB and close Cortex Control." : "Bluetooth advertising failed. Restart the bridge.")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard peripheral === manager, characteristic === result, self.central == nil else { return }
        self.central = central
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard peripheral === manager, characteristic === result, self.central?.identifier == central.identifier else { return }
        clear(); onDisconnect?()
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard peripheral === manager, let first = requests.first else { return }
        // A phone sends exactly one chunk per acknowledged write. Reject multi-write batches atomically.
        guard requests.count == 1, first.characteristic.uuid == Self.commandID, first.offset == 0,
              first.central.identifier == central?.identifier, let bytes = first.value else {
            peripheral.respond(to: first, withResult: .writeNotPermitted); return
        }
        guard outgoing.isEmpty else { peripheral.respond(to: first, withResult: .insufficientResources); return }
        var acknowledged = false
        do {
            let message = try receiver.receive(bytes)
            guard let message else { peripheral.respond(to: first, withResult: .success); return }
            guard let object = try JSONSerialization.jsonObject(with: message) as? [String: Any], let onMessage else { throw BridgeFailure.protocolError }
            // Acknowledge delivery before USB I/O, which may take longer than an ATT write timeout.
            peripheral.respond(to: first, withResult: .success)
            acknowledged = true
            let response = onMessage(object)
            guard manager === peripheral, central?.identifier == first.central.identifier else { return }
            let data = try JSONSerialization.data(withJSONObject: response)
            transfer &+= 1
            outgoing = try Chunks.split(data, limit: min(first.central.maximumUpdateValueLength, 512), transfer: transfer)
            outgoingIndex = 0; drain()
        } catch {
            if !acknowledged { peripheral.respond(to: first, withResult: .unlikelyError) }
            // Do not acknowledge a request twice. Invalid transfers require a fresh connection.
            resetConnection(); onDisconnect?()
        }
    }
    private func drain() {
        guard let manager, let central, let result else { return }
        while outgoingIndex < outgoing.count {
            guard manager.updateValue(outgoing[outgoingIndex], for: result, onSubscribedCentrals: [central]) else { return }
            outgoingIndex += 1
        }
        outgoing.removeAll(); outgoingIndex = 0
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { if peripheral === manager { drain() } }
}
#endif
