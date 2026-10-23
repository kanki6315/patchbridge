#if os(macOS)
import Foundation
import CoreBluetooth

/// Callbacks run on the owner's queue, and the owner calls these methods from it.
/// Bluetooth itself runs on the peripheral's own queue, so USB work on the owner's
/// queue never delays a Bluetooth acknowledgement.
protocol BridgePeripheral: AnyObject {
    var onMessage: ((UUID, [String: Any]) -> PeripheralReply)? { get set }
    var onDisconnect: ((UUID) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    func start(name: String)
    func stop()
}

/// CoreBluetooth adapter around `CentralRouter`, which owns all per-device state.
final class BLEPeripheral: NSObject, BridgePeripheral, CBPeripheralManagerDelegate {
    var onMessage: ((UUID, [String: Any]) -> PeripheralReply)? {
        get { router.onMessage } set { router.onMessage = newValue }
    }
    var onDisconnect: ((UUID) -> Void)? {
        get { router.onDisconnect } set { router.onDisconnect = newValue }
    }
    var onStatus: ((String) -> Void)?
    private let owner: DispatchQueue
    private let radio = DispatchQueue(label: "patchbridge.bluetooth")
    private let router: CentralRouter
    private var manager: CBPeripheralManager?
    private var name = "Mac"
    private var centrals = [UUID: CBCentral]()
    private var result: CBMutableCharacteristic?
    private static let serviceID = CBUUID(string: "79A90001-6E15-4C9F-AC53-147F7E639B01")
    private static let commandID = CBUUID(string: "79A90002-6E15-4C9F-AC53-147F7E639B01")
    private static let resultID = CBUUID(string: "79A90003-6E15-4C9F-AC53-147F7E639B01")
    /// `queue` is the owner's queue, where callbacks are delivered.
    init(queue: DispatchQueue) {
        owner = queue; router = CentralRouter(radio: radio, owner: queue)
        super.init()
        router.send = { [unowned self] id, data in
            // A central that left has nothing to receive; discard its chunks.
            guard let manager, let result, let central = centrals[id] else { return true }
            return manager.updateValue(data, for: result, onSubscribedCentrals: [central])
        }
        router.resetService = { [unowned self] in
            centrals.removeAll()
            // Removing the service invalidates the phone's characteristics; fresh discovery is required.
            if let manager, manager.state == .poweredOn { installService(manager) }
        }
    }
    // The radio queue never waits on the owner's queue, so these syncs cannot deadlock.
    func start(name: String) { radio.sync { stopRadio(); self.name = name; manager = CBPeripheralManager(delegate: self, queue: radio) } }
    func stop() { radio.sync { stopRadio() } }
    private func stopRadio() {
        manager?.delegate = nil; manager?.stopAdvertising(); manager?.removeAllServices(); manager = nil
        centrals.removeAll(); result = nil; router.removeAll()
    }
    private func status(_ text: String) { owner.async { [weak self] in self?.onStatus?(text) } }
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
        centrals.removeAll(); router.removeAll()
        if peripheral.state == .poweredOn { installService(peripheral) }
        else {
            status(peripheral.state == .unauthorized ? "Allow Bluetooth access for Patchbridge in System Settings."
                : peripheral.state == .poweredOff ? "Bluetooth is off. Turn it on to connect your iPhone or iPad."
                : "Bluetooth is unavailable. Check System Settings or restart the bridge.")
        }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral === manager else { return }
        guard error == nil else { status("Bluetooth service couldn’t start. Restart the bridge."); return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID], CBAdvertisementDataLocalNameKey: name])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral === manager else { return }
        status(error == nil ? "Open Patchbridge on your iPhone or iPad and choose this Mac. Connect the QC over USB and close Cortex Control." : "Bluetooth advertising failed. Restart the bridge.")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard peripheral === manager, characteristic === result else { return }
        centrals[central.identifier] = central
        router.subscribe(central.identifier, limit: central.maximumUpdateValueLength)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard peripheral === manager, characteristic === result else { return }
        centrals[central.identifier] = nil
        router.unsubscribe(central.identifier)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard peripheral === manager, let first = requests.first else { return }
        // A phone sends exactly one chunk per acknowledged write. Reject multi-write batches atomically.
        guard requests.count == 1, first.characteristic.uuid == Self.commandID, first.offset == 0, let bytes = first.value else {
            peripheral.respond(to: first, withResult: .writeNotPermitted); return
        }
        // Acknowledged here, before any USB I/O, which may take longer than an ATT write timeout.
        switch router.write(first.central.identifier, bytes) {
        case .success: peripheral.respond(to: first, withResult: .success)
        case .busy: peripheral.respond(to: first, withResult: .insufficientResources)
        case .notPermitted: peripheral.respond(to: first, withResult: .writeNotPermitted)
        case .failed: peripheral.respond(to: first, withResult: .unlikelyError)
        }
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { if peripheral === manager { router.drain() } }
}
#endif
