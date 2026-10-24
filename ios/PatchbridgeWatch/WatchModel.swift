import SwiftUI
import WatchConnectivity
import WatchKit

final class WatchModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var state = WatchState()
    @Published private(set) var reachable = false
    @Published private(set) var sending = false
    @Published var error: String?
    @Published var page = 0
    @Published var selectedParameter = "" {
        didSet { UserDefaults.standard.set(selectedParameter, forKey: "watch.parameter.\(state.presetID)") }
    }
    private var inFlight: UUID?
    private var deadline = Date.distantPast
    private var lastReply = Date.distantPast
    private var active = false
    private var lastTune = Date.distantPast
    private var wasInTune = false
    var ready: Bool { reachable && state.ready }
    var canAct: Bool { ready && !sending && !state.busy }
    var parameter: WatchParameter? { state.parameters.first { $0.id == selectedParameter } ?? state.parameters.first }
    private var demo = false

    override init() {
        super.init()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            demo = true; reachable = true
            state = Self.fixture
            if ProcessInfo.processInfo.arguments.contains("--tuner") { page = 1 }
            if ProcessInfo.processInfo.arguments.contains("--adjust") { page = 2 }
            return
        }
        #endif
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    func setActive(_ value: Bool) {
        active = value
        if demo { reachable = value; return }
        if !value { reachable = false }
        if value { tick() }
    }
    func tick() {
        guard !demo else { return }
        if Date() > deadline, inFlight != nil {
            inFlight = nil; sending = false; reachable = false
            error = "No reply. Check the QC before trying again."
        }
        if Date().timeIntervalSince(lastReply) > 3 { reachable = false }
        guard active, inFlight == nil else { return }
        send(WatchRequest(action: "status", flag: page == 1), mutation: false)
    }
    @discardableResult func command(_ action: String, target: String? = nil, value: Double? = nil, flag: Bool? = nil) -> Bool {
        guard canAct else { return false }
        error = nil
        if demo {
            switch action {
            case "scene": state.scene = target ?? "F"
            case "mute": state.muted = flag
            case "parameter":
                if let i = state.parameters.firstIndex(where: { $0.id == target }), let value {
                    state.parameters[i].value = value; state.parameters[i].formatted = String(format: "%.1f", value); state.dirty = true
                }
            default: break
            }
            return true
        }
        // A status poll may be in flight: don't enqueue a mutation behind it.
        guard inFlight == nil else { error = "Refreshing. Try again."; return false }
        return send(WatchRequest(action: action, token: state.token, target: target, value: value, flag: flag), mutation: true)
    }
    @discardableResult private func send(_ request: WatchRequest, mutation: Bool) -> Bool {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { reachable = false; return false }
        guard let data = try? JSONEncoder().encode(request) else { return false }
        let flight = UUID(); inFlight = flight; deadline = Date().addingTimeInterval(4); sending = mutation
        session.sendMessageData(data, replyHandler: { [weak self] data in
            DispatchQueue.main.async {
                guard let self, self.inFlight == flight else { return }
                self.inFlight = nil; self.sending = false
                guard let reply = try? JSONDecoder().decode(WatchReply.self, from: data), reply.state.version == 1 else {
                    self.reachable = false; self.error = "Update Patchbridge on both devices."; return
                }
                let changedPreset = self.state.presetID != reply.state.presetID
                self.state = reply.state
                if changedPreset { self.selectedParameter = UserDefaults.standard.string(forKey: "watch.parameter.\(reply.state.presetID)") ?? "" }
                self.lastReply = Date(); self.reachable = self.active
                if let error = reply.error { self.error = error }
                let inTune = self.ready && self.page == 1 && abs(reply.state.cents ?? 100) <= 2
                if inTune && !self.wasInTune && Date().timeIntervalSince(self.lastTune) > 2 {
                    WKInterfaceDevice.current().play(.click); self.lastTune = Date()
                }
                self.wasInTune = inTune
            }
        }, errorHandler: { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.inFlight == flight else { return }
                self.inFlight = nil; self.sending = false; self.reachable = false
                if mutation { self.error = "Delivery uncertain. Check the QC before trying again." }
            }
        })
        return true
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { [weak self] in self?.tick() }
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            if !session.isReachable { self?.reachable = false }
            self?.tick()
        }
    }
    #if DEBUG
    static var fixture: WatchState {
        var state = WatchState()
        state.ready = true; state.demo = true; state.presetID = "demo"; state.presetName = "Dirty Riffage"
        state.scene = "F"; state.scenes = ("ABCDEFGH").map { "Scene \($0)" }; state.dirty = true
        state.canSwitchScenes = true; state.tunerAvailable = true; state.canMute = true; state.muted = true
        state.note = "A"; state.octave = 2; state.cents = 2
        state.parameters = [WatchParameter(block: "comp", parameter: "threshold", blockName: "Opto Comp", name: "Threshold", unit: "dB", value: -30.1, minimum: -60, maximum: 12, step: 0.1, formatted: "−30.1")]
        return state
    }
    #endif
}
