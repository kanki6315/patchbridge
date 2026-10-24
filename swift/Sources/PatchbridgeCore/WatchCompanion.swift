import Foundation

/// Small, versioned Watch Connectivity payloads. No background transfer queues contain commands.
struct WatchState: Codable {
    var version = 1
    var token = ""
    var context = ""
    var ready = false
    var demo = false
    var busy = false
    var message: String?
    var presetID = ""
    var presetName = "Patchbridge"
    var scene = ""
    var scenes: [String] = []
    var dirty = false
    var canSwitchScenes = false
    var canBrowsePresets = false
    var canSwitchPresets = false
    var listingPresets = false
    var presets: [WatchPreset] = []
    var parameters: [WatchParameter] = []
    var tunerAvailable = false
    var canMute = false
    var muted: Bool?
    var mutePending = false
    var note: String?
    var octave: Int?
    var cents: Double?
}
struct WatchPreset: Codable, Identifiable {
    var id: String
    var name: String
    var number: Int
}
struct WatchParameter: Codable, Identifiable {
    var id: String { block + "/" + parameter }
    var block: String
    var parameter: String
    var blockName: String
    var name: String
    var unit: String
    var value: Double
    var minimum: Double
    var maximum: Double
    var step: Double
    var formatted: String
    var category = "CMP"
}
struct WatchRequest: Codable {
    var version = 1
    var id = UUID().uuidString
    var action: String
    var token = ""
    var target: String?
    var value: Double?
    var flag: Bool?
}
struct WatchReply: Codable {
    var state: WatchState
    var error: String?
}

/// A short-lived server-issued context plus a replay guard protects wrist actions from stale UI.
struct WatchCommandGate {
    private(set) var token = UUID().uuidString
    private(set) var contextID = UUID().uuidString
    private var context = Data()
    private var leases: [String: Date] = [:]
    private var seen: [String] = []
    mutating func issue(context: Data, now: Date = Date(), renew: Bool = true) -> String {
        if context != self.context {
            self.context = context; contextID = UUID().uuidString
            token = UUID().uuidString; leases.removeAll()
        }
        if renew {
            token = UUID().uuidString
            leases = leases.filter { (0...5).contains(now.timeIntervalSince($0.value)) }
            leases[token] = now
        }
        return token
    }
    mutating func accepts(_ request: WatchRequest, now: Date = Date()) -> Bool {
        guard request.version == 1, let issuedAt = leases[request.token],
              (0...5).contains(now.timeIntervalSince(issuedAt)), !seen.contains(request.id) else { return false }
        leases.removeValue(forKey: request.token)
        seen.append(request.id)
        if seen.count > 128 { seen.removeFirst() }
        return true
    }
}
