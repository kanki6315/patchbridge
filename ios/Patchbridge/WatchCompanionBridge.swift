import Foundation
import WatchConnectivity
import UIKit

/// All device commands stay on the phone's main-thread coordinator. The watch never owns USB/BLE.
final class WatchCompanionBridge: NSObject, WCSessionDelegate {
    weak var phone: PhoneModel?
    private var gate = WatchCommandGate()
    private var lease: Timer?
    private var watchTunerUntil = Date.distantPast
    init(phone: PhoneModel) {
        self.phone = phone
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        lease = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, Date() > self.watchTunerUntil else { return }
            self.phone?.tuner.setWatchOpen(false)
        }
    }
    deinit { lease?.invalidate() }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let request = try? JSONDecoder().decode(WatchRequest.self, from: messageData)
            let error = request.map(self.handle) ?? "Update Patchbridge on both devices."
            let reply = WatchReply(state: self.state(), error: error)
            replyHandler((try? JSONEncoder().encode(reply)) ?? Data())
        }
    }
    private var foreground: Bool { UIApplication.shared.applicationState == .active }
    private func handle(_ request: WatchRequest) -> String? {
        guard request.version == 1, let phone else { return "Update Patchbridge on both devices." }
        // Refresh the context before validating: a physical/phone change invalidates old controls.
        let current = state(renew: false)
        if request.action == "status" {
            if current.ready, request.flag == true, phone.tuner.available {
                watchTunerUntil = Date().addingTimeInterval(3)
                phone.tuner.setWatchOpen(true)
            } else { watchTunerUntil = .distantPast; phone.tuner.setWatchOpen(false) }
            return nil
        }
        guard current.ready else { return current.message ?? "Open Patchbridge on iPhone." }
        guard gate.accepts(request) else { return "The preset changed or this control expired. Try again." }
        guard !current.busy else { return "Wait for the QC to finish the last change." }
        phone.notice = nil
        switch request.action {
        case "scene":
            guard current.canSwitchScenes, let scene = request.target, PresetSnapshot.sceneLetters.contains(scene) else { return "Scene switching is unavailable." }
            phone.selectScene(scene)
        case "presets":
            guard current.canBrowsePresets else { return "Preset browsing is unavailable." }
            phone.coordinator.listPresets()
        case "preset":
            guard current.canSwitchPresets, !current.dirty, let id = request.target,
                  current.presets.contains(where: { $0.id == id }) else { return "Save or discard your edits on iPhone before switching presets." }
            phone.selectPreset(id, mode: .clean)
        case "parameter":
            guard let p = current.parameters.first(where: { $0.id == request.target }), let value = request.value,
                  value.isFinite, (p.minimum...p.maximum).contains(value),
                  let control = phone.editor.control(blockID: p.block, parameterID: p.parameter),
                  let wire = control.wireValue(display: control.snapped(value)), control.acceptsEdit(wire) else { return "This parameter can no longer be adjusted." }
            phone.edit(p.block, p.parameter, wire)
        case "mute":
            guard current.canMute, !current.mutePending, let flag = request.flag else { return "Open the tuner and wait for its current mute state." }
            phone.tuner.setMuted(flag)
        default: return "Unsupported watch action."
        }
        return phone.notice
    }
    private func state(renew: Bool = true) -> WatchState {
        guard let phone else { return WatchState() }
        var state = WatchState()
        state.demo = phone.usesLocalFixture
        state.ready = phone.ready && foreground
        state.busy = phone.busy || phone.editor.pending != nil
        state.message = !foreground ? "Keep Patchbridge open on iPhone." : !phone.ready ? "Connect to your Mac in Patchbridge on iPhone." : phone.notice ?? phone.error ?? phone.tuner.error ?? phone.coordinator.presetListError
        if state.ready {
            switch phone.sceneSwitch {
            case .notApplied?: state.message = "Scene not applied. Try again."
            case .unknown?: state.message = "Scene change uncertain. Check the QC before trying again."
            default: break
            }
            switch phone.coordinator.presetSwitch {
            case .notApplied(_, let reason)?: state.message = "Preset not loaded. " + reason
            case .unknown?: state.message = "Preset change uncertain. Check the QC before trying again."
            default: break
            }
        }
        if let s = phone.snapshot {
            state.presetID = s.preset_id; state.presetName = s.name; state.scene = s.scene; state.dirty = s.dirty
            state.scenes = PresetSnapshot.sceneLetters.enumerated().map { index, letter in
                let name = phone.sceneName(index)
                return name.isEmpty ? "Scene \(letter)" : "\(letter) · \(name)"
            }
            state.parameters = s.blocks.flatMap { block in
                phone.parameters(block).compactMap { id -> WatchParameter? in
                    guard phone.editor.readOnlyReason(blockID: block.id, parameterID: id) == nil,
                          let c = phone.editor.control(blockID: block.id, parameterID: id), c.kind == "number",
                          let raw = phone.editor.value(blockID: block.id, parameterID: id), let value = c.displayValue(raw),
                          let lo = c.minimum, let hi = c.maximum, lo < hi else { return nil }
                    return WatchParameter(block: block.id, parameter: id, blockName: phone.name(block), name: c.name.capitalized,
                                          unit: c.unit, value: value, minimum: lo, maximum: hi, step: c.increment, formatted: c.formatted(value), category: phone.category(block).code)
                }
            }
        }
        state.parameters = Array(state.parameters.prefix(64))
        state.canSwitchScenes = phone.canSwitchScenes
        state.canBrowsePresets = phone.coordinator.presetBrowsingAvailable
        state.canSwitchPresets = phone.coordinator.presetSwitchAvailable
        state.listingPresets = phone.coordinator.listingPresets
        state.presets = phone.coordinator.presetList?.entries.prefix(32).map { WatchPreset(id: $0.id, name: $0.name, number: $0.number) } ?? []
        state.tunerAvailable = phone.tuner.available
        state.canMute = phone.tuner.canMute && phone.tuner.mode == .open && phone.tuner.muted != nil
        state.muted = phone.tuner.muted; state.mutePending = phone.tuner.requestedMute != nil
        if state.ready, let pitch = phone.tuner.readout.pitch {
            state.note = pitch.note; state.octave = pitch.octave; state.cents = pitch.cents
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        // Pitch and messages may change every poll; neither changes an edit's identity.
        var context = state
        context.note = nil; context.octave = nil; context.cents = nil; context.message = nil
        state.token = gate.issue(context: (try? encoder.encode(context)) ?? Data(), renew: renew)
        state.context = gate.contextID
        return state
    }
}
