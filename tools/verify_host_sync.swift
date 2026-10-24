// Opt-in hardware probe: compile alongside PatchbridgeCore sources. No Bluetooth radio,
// edits, saves, or mute commands. Uses the production LiveBridgeBackend and its caches.
import Foundation

private final class NoClientsPeripheral: BridgePeripheral {
    var onMessage: ((UUID, [String: Any]) -> PeripheralReply)?
    var onDisconnect: ((UUID) -> Void)?
    var onStatus: ((String) -> Void)?
    func start(name: String) {}
    func stop() {}
    func notify(_ id: UUID, message: [String: Any]) { fatalError("No clients should receive notifications") }
}

@main struct HostSyncProbe {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 5 else { fatalError("usage: probe PYTHON SOURCE_PATH OUTPUT SECONDS") }
        let log = Diagnostics(capacity: 1024)
        let helper = try HelperClient(python: args[1], source: args[2], liveUSB: true, diagnostics: log)
        let host = LiveBridgeBackend(peripheral: NoClientsPeripheral(), makeHelper: { helper })
        try host.start()
        defer { host.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        var snapshotTimes = [Double](), directoryTimes = [Double](), catalogCounts = Set<Int>()
        var scenes = [String](), sequences = Set<Int>(), positiveReadings = Set<Int>()
        var lastSnapshot = -Double.infinity, lastDirectory = -Double.infinity
        var initialPreset: String?, initialDirty: Bool?, session: String?
        var sessionStable = true, presetStable = true, dirtyStable = true, clientsZero = true
        var failures = [String](), readyAt: Double?, ticks = [Double]()
        let duration = Double(args[4]) ?? 90
        print("Opening QC USB…"); fflush(stdout)
        while readyAt == nil || ProcessInfo.processInfo.systemUptime - (readyAt ?? started) < duration {
            let before = ProcessInfo.processInfo.systemUptime
            host.tick()
            let now = ProcessInfo.processInfo.systemUptime
            ticks.append(now - before)
            guard let shared = host.shared else { failures.append("Backend stopped"); break }
            clientsZero = clientsZero && shared.devices.isEmpty && host.presentation.devices.isEmpty
            if let current = shared.helperSession {
                if session == nil { session = current } else if session != current { sessionStable = false }
            }
            if let cached = shared.cached, cached.at != lastSnapshot {
                lastSnapshot = cached.at; snapshotTimes.append(now - started)
                if let state = cached.state as? [String: Any] {
                    if initialPreset == nil { initialPreset = state["preset_id"] as? String; initialDirty = state["dirty"] as? Bool }
                    presetStable = presetStable && initialPreset == state["preset_id"] as? String
                    dirtyStable = dirtyStable && initialDirty == state["dirty"] as? Bool
                    if let scene = state["scene"] as? String, scenes.last != scene { scenes.append(scene) }
                }
            }
            if let directory = shared.cachedPresets, directory.at != lastDirectory {
                lastDirectory = directory.at; directoryTimes.append(now - started)
            }
            if let models = shared.cachedCatalog?["models"] as? [String: Any] { catalogCounts.insert(models.count) }
            if let tuner = shared.cachedTuner {
                if let seq = tuner["seq"] as? Int { sequences.insert(seq) }
                for reading in tuner["readings"] as? [[String: Any]] ?? [] {
                    if let hz = reading["hz"] as? Double, hz > 0, let seq = reading["seq"] as? Int { positiveReadings.insert(seq) }
                }
            }
            if readyAt == nil, shared.cached != nil, shared.cachedCatalog != nil, shared.cachedPresets != nil, shared.cachedTuner != nil {
                readyAt = now
                print("CAPTURE READY: play notes and switch scenes on the QC. No clients connected."); fflush(stdout)
            }
            if now - started > duration + 60 { failures.append("Resources did not become ready within startup budget"); break }
            if ticks.count % 50 == 0 {
                print("samples=\(snapshotTimes.count) directory=\(directoryTimes.count) tuner_sequences=\(sequences.count) scenes=\(scenes.joined(separator: ",")) clients=0"); fflush(stdout)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        print("CAPTURE ENDED: comparing cached resources against fresh helper reads."); fflush(stdout)
        var comparisons = [String: Bool]()
        if let shared = host.shared, let session = shared.helperSession {
            let snapshot = shared.cached?.state as? NSDictionary
            let catalog = shared.cachedCatalog as NSDictionary?
            let directory = shared.cachedPresets?.result as NSDictionary?
            for operation in ["snapshot", "catalog", "list_presets"] {
                let reply = try helper.request(["operation": operation, "session_id": session], timeout: 40)
                let result = reply["result"] as? [String: Any]
                switch operation {
                case "snapshot": comparisons[operation] = snapshot == result?["state"] as? NSDictionary
                case "catalog": comparisons[operation] = catalog == result as NSDictionary?
                default: comparisons[operation] = directory == result as NSDictionary?
                }
            }
        }
        let report: [String: Any] = [
            "scope": "Production LiveBridgeBackend, current workspace helper, physical QC USB, radio disabled",
            "clients_zero": clientsZero, "session_stable": sessionStable,
            "preset_unchanged": presetStable, "dirty_unchanged": dirtyStable,
            "duration_seconds": ProcessInfo.processInfo.systemUptime - started,
            "ready_after_seconds": readyAt.map { $0 - started } as Any? ?? NSNull(),
            "snapshot_times": snapshotTimes, "directory_times": directoryTimes,
            "catalog_model_counts": catalogCounts.sorted(), "observed_scenes": scenes,
            "distinct_tuner_sequences": sequences.count, "positive_tuner_readings_observed": positiveReadings.count,
            "max_tick_seconds": ticks.max() ?? 0, "fresh_read_matches": comparisons, "failures": failures]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[3]))
        try log.reportData().write(to: URL(fileURLWithPath: args[3] + ".diagnostics.json"))
        print("Report saved: \(args[3])"); fflush(stdout)
    }
}
