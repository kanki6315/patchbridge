import SwiftUI

private enum WristTheme {
    static let ground = Color(red: 13/255, green: 14/255, blue: 10/255)
    static let raised = Color(red: 36/255, green: 36/255, blue: 31/255)
    static let signal = Color(red: 209/255, green: 225/255, blue: 74/255)
    static let ink = Color(red: 242/255, green: 242/255, blue: 238/255)
    static let muted = Color(red: 177/255, green: 178/255, blue: 171/255)
    static func category(_ code: String) -> Color {
        let hex: UInt32 = ["CMP": 0x62c797, "CAP": 0xec9ca3, "DRV": 0xffb65c, "AMP": 0xf27870,
                           "CAB": 0xc49c82, "MOD": 0xd88ad2, "DLY": 0x72baf1, "REV": 0x88dfec,
                           "WAH": 0x55c3c7, "PIT": 0xad9ce9][code] ?? 0xb1b2ab
        return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct WatchRootView: View {
    @ObservedObject var model: WatchModel
    var body: some View {
        TabView(selection: $model.page) {
            NavigationStack { NowPlayingScreen(model: model) }.tag(0)
            NavigationStack { WristTunerScreen(model: model) }.tag(1)
            NavigationStack { QuickAdjustScreen(model: model) }.tag(2)
        }
        .tabViewStyle(.page).tint(WristTheme.signal)
        .foregroundStyle(WristTheme.ink)
        .containerBackground(WristTheme.ground, for: .navigation)
        .alert("Patchbridge", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

private struct WatchConnectionNotice: View {
    @ObservedObject var model: WatchModel
    var body: some View {
        if !model.ready {
            Label(model.reachable ? model.state.message ?? "Connect on iPhone." : "Open Patchbridge on your nearby iPhone.", systemImage: "iphone")
                .font(.footnote).foregroundStyle(WristTheme.muted).fixedSize(horizontal: false, vertical: true)
        } else if let message = model.state.message {
            Text(message).font(.footnote).foregroundStyle(WristTheme.muted)
        }
    }
}

private struct NowPlayingScreen: View {
    @ObservedObject var model: WatchModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.state.presetName).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                Label(model.state.demo ? "Demo · local only" : model.ready ? "Connected" : "Not connected", systemImage: model.ready ? "checkmark.circle.fill" : "link.badge.plus")
                    .font(.caption2).foregroundStyle(WristTheme.muted)
                WatchConnectionNotice(model: model)
                NavigationLink {
                    List {
                        WatchConnectionNotice(model: model)
                        ForEach(Array(model.state.scenes.enumerated()), id: \.offset) { index, title in
                        let letter = String(Array("ABCDEFGH")[index])
                        Button { model.command("scene", target: letter) } label: {
                            HStack { Text(title); Spacer(); if model.state.scene == letter { Image(systemName: "checkmark") } }
                        }.disabled(!model.canAct)
                        }
                    }.navigationTitle("Scenes")
                } label: {
                    HStack { Text(model.state.scene.isEmpty ? "Scenes" : "Scene \(model.state.scene)").bold(); Spacer(); Image(systemName: "chevron.right") }
                }
                .buttonStyle(.borderedProminent).tint(WristTheme.signal).foregroundStyle(WristTheme.ground)
                .disabled(!model.canAct || !model.state.canSwitchScenes)
                NavigationLink { WristPresetsScreen(model: model) } label: { Label("Presets", systemImage: "list.bullet") }
                    .disabled(!model.ready || !model.state.canBrowsePresets)
                if model.sending || model.state.busy { Label("Waiting for QC…", systemImage: "clock").font(.caption2) }
                if model.state.dirty { Label("Unsaved", systemImage: "circle.fill").font(.caption2).foregroundStyle(WristTheme.signal) }
            }.padding(.horizontal, 2)
        }.navigationTitle("Patchbridge")
    }
}

private struct WristPresetsScreen: View {
    @ObservedObject var model: WatchModel
    @State private var target: WatchPreset?
    var body: some View {
        List {
            WatchConnectionNotice(model: model)
            if model.state.dirty { Text("Save or discard edits on iPhone to switch presets.").font(.footnote) }
            if model.state.listingPresets { ProgressView("Reading presets…") }
            Button("Refresh presets") { model.command("presets") }.disabled(!model.canAct || model.state.listingPresets)
            if model.state.presets.count == 32 { Text("First 32 presets. Open iPhone for the full list.").font(.footnote) }
            ForEach(model.state.presets) { preset in
                Button { target = preset } label: {
                    VStack(alignment: .leading) { Text(preset.name); Text("Slot \(preset.number)").font(.caption2).foregroundStyle(WristTheme.muted) }
                }.disabled(!model.canAct || !model.state.canSwitchPresets || model.state.dirty || preset.id == model.state.presetID)
            }
        }.navigationTitle("Presets")
            .onAppear { if model.state.presets.isEmpty { model.command("presets") } }
            .confirmationDialog("Load \(target?.name ?? "preset")?", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }), titleVisibility: .visible) {
                Button("Load preset") { if let target { model.command("preset", target: target.id) }; target = nil }
            }
    }
}

private struct WristTunerScreen: View {
    @ObservedObject var model: WatchModel
    private var cents: Double? { model.ready ? model.state.cents : nil }
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                WatchConnectionNotice(model: model)
                if model.ready && !model.state.tunerAvailable { Text("Tuner unavailable on this bridge.").font(.footnote) }
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(model.ready ? model.state.note ?? "–" : "–").font(.system(size: 64, weight: .bold))
                    Text(model.ready ? model.state.octave.map(String.init) ?? "" : "").font(.title2.bold())
                }.minimumScaleFactor(0.7).lineLimit(1)
                    .accessibilityElement(children: .combine).accessibilityLabel("Note \(model.ready ? model.state.note ?? "No signal" : "Unavailable") \(model.ready ? model.state.octave.map(String.init) ?? "" : "")")
                Text(cents.map { String(format: "%+.0f cents", $0) } ?? "No signal").font(.headline.monospacedDigit()).foregroundStyle(WristTheme.muted)
                HStack(spacing: 5) {
                    Text("♭")
                    GeometryReader { geometry in
                        ZStack {
                            HStack { ForEach(0..<11) { i in Rectangle().fill(i == 5 ? WristTheme.signal : WristTheme.muted.opacity(0.5)).frame(width: 1, height: i == 5 ? 27 : 14); if i < 10 { Spacer(minLength: 0) } } }
                            if let cents {
                                Circle().fill(WristTheme.signal).frame(width: 8, height: 8)
                                    .position(x: 4 + (geometry.size.width - 8) * (min(50, max(-50, cents)) + 50) / 100, y: geometry.size.height / 2)
                            }
                        }.frame(height: geometry.size.height)
                    }.frame(height: 30)
                    Text("♯")
                }.accessibilityHidden(true)
                Button { model.command("mute", flag: !(model.state.muted ?? false)) } label: {
                    Label(model.state.mutePending ? "Confirming…" : model.state.muted == true ? "Output muted" : "Mute output", systemImage: model.state.muted == true ? "speaker.slash.fill" : "speaker.wave.2")
                        .font(.footnote)
                }.disabled(!model.canAct || !model.state.canMute || model.state.mutePending)
                    .accessibilityHint(model.state.muted == true ? "Unmutes the Quad Cortex" : "Mutes the Quad Cortex")
                if model.state.demo { Text("Demo pitch").font(.caption2).foregroundStyle(WristTheme.muted) }
            }
        }.navigationTitle("Tuner")
    }
}

private struct QuickAdjustScreen: View {
    @ObservedObject var model: WatchModel
    @State private var editing = false
    @State private var draft = 0.0
    @State private var token = ""
    @FocusState private var crownFocused: Bool
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                WatchConnectionNotice(model: model)
                if let p = model.parameter {
                    NavigationLink {
                        List(model.state.parameters) { parameter in
                            Button { model.selectedParameter = parameter.id; editing = false } label: {
                                VStack(alignment: .leading) { Text(parameter.name); Text(parameter.blockName).font(.caption2).foregroundStyle(WristTheme.muted) }
                            }
                        }.navigationTitle("Quick controls")
                    } label: { Text(p.blockName).font(.caption).foregroundStyle(WristTheme.category(p.category)) }.buttonStyle(.plain)
                    Text(p.name).font(.headline)
                    gauge(p)
                    if editing {
                        HStack {
                            Button("Cancel") { editing = false }
                            Button("Apply") {
                                guard token == model.state.context else { editing = false; model.error = "The preset changed. Adjust again."; return }
                                if model.command("parameter", target: p.id, value: draft) { editing = false }
                            }.tint(WristTheme.signal).disabled(!model.canAct)
                        }.font(.footnote)
                        Text("Turn Crown · tap Apply").font(.caption2).foregroundStyle(WristTheme.muted)
                    } else {
                        Button("Adjust") { draft = p.value; token = model.state.context; editing = true; crownFocused = true }.disabled(!model.canAct)
                        Text(model.sending || model.state.busy ? "Waiting for QC…" : model.state.demo ? "Demo value" : model.ready ? "QC value" : "Last known value")
                            .font(.caption2).foregroundStyle(WristTheme.muted)
                    }
                } else { Text("Editable numeric controls appear here when a preset is connected.").font(.footnote).foregroundStyle(WristTheme.muted) }
            }
        }.navigationTitle("Adjust")
            .onChange(of: model.selectedParameter) { _, _ in editing = false }
            .onChange(of: model.page) { _, _ in editing = false }
            .onChange(of: model.ready) { _, ready in if !ready { editing = false } }
    }
    private func gauge(_ p: WatchParameter) -> some View {
        let shown = editing ? draft : p.value
        let fraction = min(1, max(0, (shown - p.minimum) / (p.maximum - p.minimum)))
        return ZStack {
            Circle().trim(from: 0.125, to: 0.875).stroke(WristTheme.raised, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(90))
            Circle().trim(from: 0.125, to: 0.125 + 0.75 * fraction).stroke(WristTheme.category(p.category), style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(90))
            VStack(spacing: 0) {
                Text(editing ? String(format: p.step >= 1 ? "%.0f" : "%.1f", shown) : p.formatted).font(.system(size: 32, weight: .bold)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                Text(p.unit).font(.footnote).foregroundStyle(WristTheme.muted)
                if editing { Text("Draft").font(.caption2).foregroundStyle(WristTheme.signal) }
            }.padding(.horizontal, 14)
        }.frame(width: 136, height: 126)
            .focusable(editing).focused($crownFocused)
            .digitalCrownRotation($draft, from: p.minimum, through: p.maximum, by: p.step, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(p.name), \(editing ? "draft" : "confirmed")")
            .accessibilityValue("\(shown.formatted()) \(p.unit)")
            .accessibilityAdjustableAction { direction in
                guard editing else { return }
                draft = min(p.maximum, max(p.minimum, draft + (direction == .increment ? p.step : -p.step)))
            }
    }
}
