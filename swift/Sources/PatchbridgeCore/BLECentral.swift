import Foundation
import CoreBluetooth

/// Foreground iPhone/macOS development transport. All callbacks occur on main queue.
/// Only one command may be outstanding; the caller coalesces slider movement until completion.
public protocol EditorTransport: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    var onResponse: (([String: Any]) -> Void)? { get set }
    var disconnectionReason: String? { get }
    func reconnect()
    func disconnect()
    func send(_ message: [String: Any]) throws
}

public extension EditorTransport {
    var disconnectionReason: String? { nil }
}

public protocol DiscoverableEditorTransport: EditorTransport {
    var onDiscovered: ((String, String) -> Void)? { get set }
    func selectPeripheral(_ id: String)
}

public final class BLECentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, DiscoverableEditorTransport {
    public var onDiscovered: ((String, String) -> Void)?
    private var discovered = [String: CBPeripheral]()
    private var automaticallyConnect = true
    public var onReady: (() -> Void)?
    public var onDisconnected: (() -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onResponse: (([String: Any]) -> Void)?
    public private(set) var disconnectionReason: String?
    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var command: CBCharacteristic?
    private var results: CBCharacteristic?
    private var exchange = CommandExchange()
    private var receiver = ChunkReceiver()
    private var transfer: UInt32 = 0
    private var timer: Timer?
    private static let service = CBUUID(string: "79A90001-6E15-4C9F-AC53-147F7E639B01")
    public override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main)
    }
    public convenience init(automaticallyConnect: Bool) {
        self.init(); self.automaticallyConnect = automaticallyConnect
    }
    public func selectPeripheral(_ id: String) {
        guard peripheral == nil, let selected = discovered[id] else { return }
        peripheral = selected; manager.stopScan(); onStatus?("Connecting to \(selected.name ?? "Mac")…"); manager.connect(selected)
    }
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            onStatus?("Scanning for Patchbridge")
        } else {
            let message = central.state == .poweredOff ? "Bluetooth is off. Turn it on in Settings, then reconnect."
                : central.state == .unauthorized ? "Bluetooth access is disabled. Allow Patchbridge in Settings, then reconnect."
                : "Bluetooth is unavailable. Check Settings, then reconnect."
            fail(message)
        }
    }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        discovered[peripheral.identifier.uuidString] = peripheral
        if automaticallyConnect { selectPeripheral(peripheral.identifier.uuidString) }
        else { onDiscovered?(peripheral.identifier.uuidString, peripheral.name ?? "Mac") }
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { central.cancelPeripheralConnection(peripheral); return }
        peripheral.delegate = self; peripheral.discoverServices([Self.service])
    }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { guard self.peripheral === peripheral else { return }; fail("Could not connect to your Mac", error: error) }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { guard self.peripheral?.identifier == peripheral.identifier else { return }; fail("The Bluetooth connection to your Mac ended", error: error) }
    public func reconnect() {
        guard peripheral == nil, manager.state == .poweredOn else { return }
        disconnectionReason = nil
        manager.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
    public func disconnect() { manager.stopScan(); if let peripheral { manager.cancelPeripheralConnection(peripheral) }; clear() }
    // Publish the reason before teardown: onDisconnected may release this transport immediately.
    private func fail(_ message: String, error: Error? = nil) {
        disconnectionReason = Self.failureMessage(message, error: error)
        onStatus?(disconnectionReason!)
        disconnect()
    }
    static func failureMessage(_ message: String, error: Error?) -> String {
        guard let error = error as NSError? else { return message }
        let detail = "\(message): \(error.localizedDescription) (\(error.domain) \(error.code))."
        if error.domain == CBErrorDomain,
           [CBError.Code.peerRemovedPairingInformation.rawValue, CBError.Code.encryptionTimedOut.rawValue].contains(error.code) {
            return detail + " Bluetooth pairing needs to be renewed. Forget the existing pairing in Bluetooth Settings if listed, then reconnect and accept the pairing prompt."
        }
        return detail
    }
    private func clear() {
        timer?.invalidate(); timer = nil; peripheral?.delegate = nil; peripheral = nil; command = nil; results = nil
        exchange.reset(); receiver.reset(); discovered.removeAll()
        onDisconnected?()
    }
    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard self.peripheral === peripheral, invalidatedServices.contains(where: { $0.uuid == Self.service }) else { return }
        fail("Bridge session ended. Reconnect and approve on the Mac again.")
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil else { fail("Could not discover the Mac’s Bluetooth service", error: error); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { fail("Patchbridge’s Bluetooth service is missing. Restart the Mac bridge and reconnect."); return }
        peripheral.discoverCharacteristics(nil, for: service)
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil else { fail("Could not discover the Mac’s Bluetooth characteristics", error: error); return }
        command = service.characteristics?.first { $0.uuid == CBUUID(string: "79A90002-6E15-4C9F-AC53-147F7E639B01") }
        results = service.characteristics?.first { $0.uuid == CBUUID(string: "79A90003-6E15-4C9F-AC53-147F7E639B01") }
        guard command != nil, let results else { fail("The Mac’s Bluetooth service is incomplete. Restart the Mac bridge and reconnect."); return }
        peripheral.setNotifyValue(true, for: results)
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic === results else { return }
        guard error == nil, characteristic.isNotifying else { fail("Could not enable Bluetooth responses from your Mac", error: error); return }
        onStatus?("Connected; send hello, then approve on the Mac")
        onReady?()
    }
    public func send(_ message: [String: Any]) throws {
        guard let peripheral, let command, results?.isNotifying == true else { throw ExchangeFailure.malformed }
        transfer &+= 1
        let first = try exchange.begin(message, limit: min(peripheral.maximumWriteValueLength(for: .withResponse), 512), transfer: transfer)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            self?.fail("Command timed out; no automatic retry. Reconnect to your Mac.")
        }
        peripheral.writeValue(first, for: command, type: .withResponse)
    }
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic === command else { return }
        guard error == nil else { fail("Bluetooth write failed; reconnect required", error: error); return }
        do {
            if let next = try exchange.acknowledge(), let command {
                peripheral.writeValue(next, for: command, type: .withResponse)
            }
            completeExchange()
        } catch { fail("Unexpected write acknowledgment; reconnect required", error: error) }
    }
    private func completeExchange() {
        if let response = exchange.completed() {
            timer?.invalidate(); timer = nil
            onResponse?(response)
        }
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic === results else { return }
        guard error == nil, let data = characteristic.value else { fail("Could not read a Bluetooth response from your Mac", error: error); return }
        do {
            if let complete = try receiver.receive(data) {
                guard let response = try JSONSerialization.jsonObject(with: complete) as? [String: Any] else { throw ChunkFailure.malformed }
                try exchange.accept(response)
                completeExchange()
            }
        } catch { fail("Invalid transfer; reconnect required", error: error) }
    }
}
