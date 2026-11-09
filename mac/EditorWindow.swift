import SwiftUI

/// The Mac's own session, in place of the iPhone's Bluetooth link. Shared by the iPad popover.
struct ConnectionHeader: View {
    @ObservedObject var model: PhoneModel
    let theme: PhoneTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Editing on this Mac").font(.title.bold())
            Label {
                Text("Through this Mac’s bridge, over USB").foregroundStyle(theme.muted)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.signal)
            }.font(.subheadline)
        }.accessibilityElement(children: .combine)
    }
}

struct DisconnectButton: View {
    let theme: PhoneTheme
    let action: () -> Void
    var body: some View {
        Button(role: .destructive, action: action) {
            Text("Stop editing").font(.headline).foregroundStyle(theme.danger)
                .frame(maxWidth: .infinity).frame(minHeight: 44).background(theme.raised, in: Capsule())
        }.buttonStyle(.plain).padding(.top, 4)
    }
}

/// The iPhone's session settings (keep awake, Live Activity, drop alerts) don't apply here:
/// the bridge keeps the Mac awake, and this window shows its own status.
struct ConnectionStatusSettings: View {
    @ObservedObject var model: PhoneModel
    let theme: PhoneTheme
    let fill: Color
    var body: some View {
        Text("Edits from this Mac and from connected iPhones and iPads go to the same QC. If two change it at once, the first one wins.")
            .font(.footnote).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
    }
}

/// The Mac's editor window: the iPad workspace, editing the QC through this Mac's own bridge.
/// It joins the bridge like an iPhone would (so the first edit wins if two devices change the
/// same preset), without an approval code. Edits are confirmed by QC readback, never replayed.
struct MacEditorView: View {
    @ObservedObject var bridge: MacBridgeModel
    @ObservedObject var model: PhoneModel
    @ObservedObject private var tuner: TunerModel
    let showBridge: () -> Void
    @AppStorage(AppearanceKey.theme) private var themeID = ThemeID.stage
    @AppStorage(AppearanceKey.mode) private var mode = AppearanceMode.dark
    @AppStorage(AppearanceKey.highContrast) private var highContrast = false
    @AppStorage(AppearanceKey.blocks) private var blocks = BlockPalette.patchbridge
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.colorScheme) private var systemScheme
    /// Set when the player stops editing, so a running bridge doesn't reconnect behind them.
    @State private var stoppedByPlayer = false

    init(bridge: MacBridgeModel, model: PhoneModel, showBridge: @escaping () -> Void) {
        self.bridge = bridge; self.model = model; self.showBridge = showBridge
        _tuner = ObservedObject(wrappedValue: model.tuner)
    }
    private var theme: PhoneTheme {
        PhoneTheme(themeID, daylight: mode.daylight(systemLight: systemScheme == .light),
                   highContrast: highContrast || systemContrast == .increased, blocks: BlockPalette.available.contains(blocks) ? blocks : .patchbridge)
    }
    private var phase: EditorCoordinator.Phase { model.coordinator.phase }

    var body: some View {
        NavigationStack {
            Group {
                if let staged = model.coordinator.loadingPreset {
                    PresetReloadingView(snapshot: staged, model: model, theme: theme)
                } else if model.showsPreset, model.snapshot != nil {
                    PadWorkspaceView(model: model, tuner: tuner, theme: theme)
                } else if [.connecting, .awaitingApproval, .loading, .recovering].contains(phase) {
                    PadLoadingView(theme: theme) { stop() }
                } else {
                    idle
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.ground.ignoresSafeArea())
        }
        // The shared views expect iOS's default button: no bezel, tinted label.
        .buttonStyle(.borderless)
        .foregroundStyle(theme.ink).tint(theme.signal)
        .preferredColorScheme(mode == .auto ? nil : (theme.daylight ? .light : .dark))
        .frame(minWidth: 960, minHeight: 640)
        .onAppear(perform: startIfReady)
        .onChange(of: bridge.acceptsLocalEditor) { _, _ in startIfReady() }
    }

    /// Before the bridge runs, or after the session ended: what's needed, and one button.
    private var idle: some View {
        VStack(spacing: 18) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 44, weight: .light)).foregroundStyle(theme.signal)
            VStack(spacing: 8) {
                Text(bridge.acceptsLocalEditor ? "Edit your QC on this Mac" : "Start the bridge to edit").font(.largeTitle.bold())
                Text(message).foregroundStyle(theme.muted).multilineTextAlignment(.center)
                    .frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
            }
            if bridge.acceptsLocalEditor {
                Button("Start editing") { stoppedByPlayer = false; model.start() }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            } else {
                HStack(spacing: 12) {
                    Button("Start bridge") { stoppedByPlayer = false; bridge.start() }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                        .disabled(bridge.busy || ![.stopped, .failed].contains(bridge.phase))
                    Button("Open bridge window", action: showBridge).controlSize(.large)
                }
            }
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var message: String {
        if !bridge.acceptsLocalEditor {
            return bridge.isSimulation ? "The bridge reads the simulated QC. Nothing here uses Bluetooth or USB."
                : "Connect your QC over USB and close Cortex Control. The bridge reads it and shares it with this Mac, your iPhone and your iPad."
        }
        if let error = model.error, phase == .failed { return error }
        return bridge.isSimulation ? "Edits go to the simulated QC and are confirmed by its readback."
            : "Edits go to the QC over USB and show once the QC confirms them. Connected iPhones and iPads see them too."
    }
    private func startIfReady() {
        guard bridge.acceptsLocalEditor, !stoppedByPlayer, phase == .disconnected else { return }
        model.start()
    }
    private func stop() { stoppedByPlayer = true; model.disconnect() }
}
