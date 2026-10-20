import AppKit
import SwiftUI
import ServiceManagement
import CoreBluetooth

private struct BridgePalette {
    let dark: Bool
    var ground: Color { Color(red: dark ? 0.051 : 0.969, green: dark ? 0.055 : 0.969, blue: dark ? 0.039 : 0.961) }
    var surface: Color { dark ? Color(red: 0.086, green: 0.086, blue: 0.071) : .white }
    var ink: Color { dark ? Color(red: 0.949, green: 0.949, blue: 0.933) : Color(red: 0.086, green: 0.086, blue: 0.067) }
    var muted: Color { dark ? Color(red: 0.694, green: 0.698, blue: 0.671) : Color(red: 0.333, green: 0.337, blue: 0.314) }
    var signal: Color { dark ? Color(red: 0.82, green: 0.882, blue: 0.29) : Color(red: 0.36, green: 0.392, blue: 0) }
}

/// The Patch Cable "pb" mark from docs/design/brand/patch-cable.svg, drawn in the current foreground style.
private struct PatchCableMark: View {
    private static let cable = "M5 182V123C5 90 24 74 57 74H108C133 74 147 88 147 113V132C147 139 152 139 159 141L168 144Q174 146 174 138V70H203V77H249C278 77 294 92 294 119V139C294 167 278 183 250 183H204C186 183 174 177 161 165L155 160Q149 155 142 158C134 175 120 183 100 183H54C35 183 35 155 54 155H100C112 155 119 148 119 137V116C119 108 114 104 105 104H57C42 104 35 111 35 124V182ZM203 105V149Q203 155 210 155H249C259 155 265 149 265 139V120C265 110 260 105 249 105Z"
    private static let jacks = "M10 211H29V227H10Z M13 231H26L30 237Q30 241 25 245Q20 249 15 245L9 240Q7 236 13 231Z M179 21H198V41H179Z M181 1H194L199 7Q200 11 196 14V17H180V14Q175 11 178 7Z"

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 300, size.height / 250)
            context.translateBy(x: (size.width - 300 * scale) / 2, y: (size.height - 250 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.fill(Self.path(Self.cable), with: .foreground, style: FillStyle(eoFill: true))
            var parts = Self.path(Self.jacks)
            parts.addRoundedRect(in: CGRect(x: 1, y: 181, width: 37, height: 26), cornerSize: CGSize(width: 3, height: 3))
            parts.addRoundedRect(in: CGRect(x: 169, y: 45, width: 38, height: 27), cornerSize: CGSize(width: 3, height: 3))
            context.fill(parts, with: .foreground)
        }
    }

    /// Parses the absolute M/L/H/V/C/Q/Z commands the mark uses.
    private static func path(_ data: String) -> Path {
        var tokens: [String] = []
        var current = ""
        for ch in data {
            if ch.isLetter {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(ch))
            } else if ch == " " || ch == "," {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else { current.append(ch) }
        }
        if !current.isEmpty { tokens.append(current) }
        var path = Path()
        var i = 0
        var point = CGPoint.zero
        func next() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        while i < tokens.count {
            let command = tokens[i]; i += 1
            switch command {
            case "M": point = CGPoint(x: next(), y: next()); path.move(to: point)
            case "L": point = CGPoint(x: next(), y: next()); path.addLine(to: point)
            case "H": point.x = next(); path.addLine(to: point)
            case "V": point.y = next(); path.addLine(to: point)
            case "C":
                let c1 = CGPoint(x: next(), y: next()), c2 = CGPoint(x: next(), y: next())
                point = CGPoint(x: next(), y: next()); path.addCurve(to: point, control1: c1, control2: c2)
            case "Q":
                let c = CGPoint(x: next(), y: next())
                point = CGPoint(x: next(), y: next()); path.addQuadCurve(to: point, control: c)
            default: path.closeSubpath()
            }
        }
        return path
    }
}

struct BridgeWindow: View {
    @ObservedObject var model: MacBridgeModel
    let exportReport: () -> Void
    var compact = false
    var menuActions: [(String, () -> Void)] = []
    @AppStorage("bridge.appearance") private var appearance = "Match Mac"
    @AppStorage("bridge.setupComplete") private var setupComplete = false
    @State private var setupStep = SetupStep.welcome
    @StateObject private var bluetooth = BluetoothAccess()
    @AppStorage("bridge.trustPhone") private var trustPhone = true
    @Environment(\.colorScheme) private var scheme
    private var colors: BridgePalette { BridgePalette(dark: appearance == "Stage" || (appearance == "Match Mac" && scheme == .dark)) }
    private var settingUp: Bool { !compact && !setupComplete }
    private var phone: Bool { [.awaitingApproval, .approving, .connected, .recovering].contains(model.phase) }
    private var active: Bool { ![.stopped, .failed, .stopping].contains(model.phase) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView {
            VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                PatchCableMark().foregroundStyle(colors.signal).frame(width: 26, height: 22).accessibilityHidden(true)
                Text("Patchbridge").font(.headline)
                Spacer()
                if model.isSimulation {
                    Label("Simulation", systemImage: "testtube.2").font(.caption).foregroundStyle(colors.muted)
                }
            }
            if !compact { diagram }
            if settingUp { setup } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.title).font(.system(size: compact ? 21 : 27, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                Text(model.detail).font(.system(size: 14)).foregroundStyle(colors.muted).fixedSize(horizontal: false, vertical: true)
            }
            if model.busy { ProgressView("Working…").controlSize(.small) }
            if model.phase == .awaitingApproval || model.phase == .approving {
                Text(model.presentation.approvalCode).font(.system(size: 38, weight: .semibold)).tracking(5).monospacedDigit()
                    .frame(maxWidth: .infinity).padding(.vertical, 20).background(colors.surface, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityLabel("Approval code \(model.presentation.approvalCode)")
                Text("Approve only if the phone shows the same code.")
                    .font(.callout).foregroundStyle(colors.muted)
                if model.phase == .awaitingApproval {
                    Toggle("Trust this \(model.presentation.phoneName) until Patchbridge quits", isOn: $trustPhone).toggleStyle(.checkbox)
                    Text(trustPhone ? "Reconnect on the phone skips the code. Quit Patchbridge or revoke trust to end it." : "Approval ends when the phone disconnects or the bridge restarts.")
                        .font(.caption).foregroundStyle(colors.muted)
                }
            }
            if let trusted = model.presentation.trustedPhone, model.phase != .awaitingApproval {
                HStack(spacing: 12) {
                    Image(systemName: "iphone").font(.system(size: 18)).frame(width: 36, height: 36)
                        .background(colors.surface, in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trusted).fontWeight(.semibold)
                        Text(model.phase == .connected || model.phase == .recovering ? "Trusted · connected" : "Trusted · not connected").font(.caption).foregroundStyle(colors.muted)
                    }
                    Spacer()
                    Button("Revoke Trust", role: .destructive) { model.revokeTrust() }.disabled(model.busy)
                        .accessibilityLabel("Revoke Trust for \(trusted)")
                }.font(.system(size: 14)).padding(12).background(colors.surface, in: RoundedRectangle(cornerRadius: 16))
            }
            if let preset = model.presentation.preset {
                VStack(spacing: 0) {
                    fact(model.phase == .recovering ? "Last preset" : "Preset", preset)
                    Divider()
                    fact("Scene", model.presentation.scene ?? "Unavailable")
                    Divider()
                    fact("State", model.phase == .recovering ? "Last known · reload required" : model.presentation.dirty ? "Unsaved" : "No unsaved changes")
                }.background(colors.surface, in: RoundedRectangle(cornerRadius: 16))
            }
            if model.phase == .connected || model.phase == .recovering || !model.presentation.recentEdits.isEmpty {
                recentEdits
            }
            if !compact && model.phase == .stopped {
                Toggle("Use simulation", isOn: Binding(get: { model.isSimulation }, set: model.setSimulation)).toggleStyle(.switch)
            }
            if !compact {
                Text(model.isSimulation ? "Bluetooth and USB are off. This mode uses the bundled simulator." : "CorOS 4.1.1 · Supported parameters only. Keep Cortex Control closed while connected.")
                    .font(.callout).foregroundStyle(colors.muted)
            }
            }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if settingUp { setupActions } else {
            actions
            Divider()
            HStack {
                Button("Export report…", action: exportReport)
                Spacer()
                if active {
                    Menu {
                        Button("Stop bridge") { model.stop() }
                        if model.phase == .connected && model.isSimulation {
                            Button("Simulate gain edit") { model.simulateEdit() }
                            Button("Simulate rejected edit") { model.simulateEdit(rejected: true) }
                            Button("Check connection") { model.refresh() }
                            Button("Simulate USB interruption") { model.simulateUSBRemoval() }
                            Button("Simulate helper failure") { model.simulateFailure() }
                        }
                    } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Bridge actions") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
                }
            }.font(.callout)
            if !menuActions.isEmpty {
                HStack {
                    ForEach(menuActions.indices, id: \.self) { index in
                        Button(menuActions[index].0, action: menuActions[index].1)
                    }
                }.frame(maxWidth: .infinity)
            }
            }
        }
        .padding(compact ? 20 : 28)
        .foregroundStyle(colors.ink).tint(colors.signal)
        .frame(minWidth: compact ? 320 : 480, maxWidth: .infinity, minHeight: compact ? 560 : 630, maxHeight: compact ? 560 : .infinity, alignment: .topLeading)
        .background(colors.ground)
        .preferredColorScheme(appearance == "Match Mac" ? nil : appearance == "Stage" ? .dark : .light)
        .onChange(of: setupComplete) { _, complete in if !complete { setupStep = .welcome } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            bluetooth.refresh()
            if setupStep == .bluetooth && bluetooth.authorization == .allowedAlways { setupStep = .ready }
        }
    }
    private var recentEdits: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent edits").font(.headline)
                Spacer()
                if !model.presentation.recentEdits.isEmpty {
                    Button("Clear") { model.clearRecentEdits() }.font(.caption).disabled(model.busy)
                }
            }
            if model.presentation.recentEdits.isEmpty {
                Text("No edits in this session yet.").foregroundStyle(colors.muted).font(.callout)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.presentation.recentEdits.prefix(compact ? 3 : 12))) { edit in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: edit.outcome == .confirmed ? "checkmark" : "exclamationmark.triangle")
                                .foregroundStyle(edit.outcome == .confirmed ? colors.muted : colors.dark ? Color(red: 1, green: 0.77, blue: 0.41) : Color(red: 0.62, green: 0.32, blue: 0))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(edit.title).fontWeight(.medium)
                                    Spacer(minLength: 8)
                                    if let value = edit.value { Text(value).monospacedDigit() }
                                }
                                Text(edit.outcome == .rejected ? "Not applied · \(edit.detail)" : edit.outcome == .unknown ? "Outcome unknown · \(edit.detail)" : edit.detail).foregroundStyle(colors.muted)
                                if !compact {
                                    HStack {
                                        Text(edit.context)
                                        Spacer()
                                        Text(edit.date, style: .time).monospacedDigit()
                                    }.font(.caption).foregroundStyle(colors.muted)
                                }
                            }
                        }.font(.system(size: 13)).padding(12)
                        Divider()
                    }
                }.background(colors.surface, in: RoundedRectangle(cornerRadius: 16))
                if compact && model.presentation.recentEdits.count > 3 {
                    Text("Open Patchbridge for more edits.").font(.caption).foregroundStyle(colors.muted)
                }
            }
        }
    }
    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(colors.muted).frame(width: 86, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 14)).padding(14)
    }
    private var diagram: some View {
        HStack(alignment: .top, spacing: 10) {
            node("iphone", phone ? model.presentation.phoneName : "iPhone", live: model.phase == .connected)
            link(model.isSimulation ? "Simulated" : "Bluetooth", live: model.phase == .connected)
            node("laptopcomputer", model.presentation.macName, live: active)
            link(model.phase == .recovering ? "Paused" : model.isSimulation ? "Simulated" : "USB", live: model.phase == .connected)
            node("square.grid.3x3.fill", model.isSimulation ? "QC simulator" : "Quad Cortex", live: model.phase == .connected)
        }.padding(.vertical, 10).accessibilityElement(children: .combine)
    }
    private func node(_ symbol: String, _ name: String, live: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 25)).frame(width: 62, height: 62)
                .background(colors.surface, in: Circle()).overlay(Circle().stroke(live ? colors.signal : colors.muted.opacity(0.4), lineWidth: 1))
                .accessibilityHidden(true)
            Text(name).font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center).lineLimit(3).fixedSize(horizontal: false, vertical: true).help(name)
        }.frame(maxWidth: .infinity)
    }
    private func link(_ label: String, live: Bool) -> some View {
        VStack(spacing: 8) {
            Text(label).font(.system(size: 10)).foregroundStyle(colors.muted)
            Path { path in path.move(to: .zero); path.addLine(to: CGPoint(x: 52, y: 0)) }.stroke(live ? colors.muted : colors.signal, style: StrokeStyle(lineWidth: 2, dash: live ? [] : [5, 4])).frame(height: 2)
        }.frame(width: 52).padding(.top, 18)
    }
    private enum SetupStep { case welcome, bluetooth, ready }
    @ViewBuilder private var setup: some View {
        let denied = bluetooth.authorization == .denied || bluetooth.authorization == .restricted
        let (title, detail): (String, String) = switch setupStep {
        case .welcome: ("Edit your QC from your iPhone", "This Mac connects to the Quad Cortex over USB and passes edits to your iPhone over Bluetooth.")
        case .bluetooth where denied: ("Bluetooth access is off", "Allow Patchbridge in System Settings → Privacy & Security → Bluetooth to connect your iPhone.")
        case .bluetooth: ("Patchbridge needs Bluetooth", "Your iPhone reaches the QC through this Mac. Continue to request Bluetooth access.")
        case .ready: ("Ready when you are", "Start the bridge whenever you want to use your iPhone. Patchbridge stays in the menu bar.")
        }
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 27, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.system(size: 14)).foregroundStyle(colors.muted).fixedSize(horizontal: false, vertical: true)
        }
        switch setupStep {
        case .welcome:
            VStack(spacing: 0) {
                let steps = ["Connect the QC to this Mac with USB", "Keep Cortex Control closed", "Open Patchbridge on your iPhone"]
                ForEach(steps.indices, id: \.self) { index in
                    if index > 0 { Divider() }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)").foregroundStyle(colors.muted).monospacedDigit()
                        Text(steps[index]).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: 14)).padding(14)
                }
            }.background(colors.surface, in: RoundedRectangle(cornerRadius: 16))
        case .bluetooth:
            EmptyView()
        case .ready:
            VStack(spacing: 0) { fact("Visible as", model.presentation.macName) }.background(colors.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }
    @ViewBuilder private var setupActions: some View {
        HStack {
            switch setupStep {
            case .welcome:
                Button("Try the simulation") { model.setSimulation(true); setupComplete = true }
                Spacer()
                Button("Continue") { setupStep = bluetooth.authorization == .allowedAlways ? .ready : .bluetooth }.buttonStyle(.borderedProminent)
            case .bluetooth where bluetooth.authorization == .denied || bluetooth.authorization == .restricted:
                Button("Set up later") { setupComplete = true }
                Spacer()
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
                }.buttonStyle(.borderedProminent)
            case .bluetooth:
                Button("Back") { setupStep = .welcome }
                Spacer()
                Button("Continue") {
                    bluetooth.request { if bluetooth.authorization == .allowedAlways { setupStep = .ready } }
                }.buttonStyle(.borderedProminent).disabled(bluetooth.requesting)
            case .ready:
                Button("Not now") { setupComplete = true }
                Spacer()
                Button("Start bridge") { setupComplete = true; model.start() }.buttonStyle(.borderedProminent)
            }
        }.controlSize(.large)
    }
    @ViewBuilder private var actions: some View {
        HStack {
            if model.phase == .awaitingApproval || model.phase == .approving {
                Button(model.phase == .approving ? "Disconnect" : "Deny") { model.disconnectPhone() }
                Spacer()
                Button(model.phase == .approving ? "Approved" : "Approve") { model.approve(trust: trustPhone) }.buttonStyle(.borderedProminent).disabled(model.phase == .approving)
            } else if model.phase == .connected || model.phase == .recovering {
                Spacer()
                Button("Disconnect iPhone", role: .destructive) { model.disconnectPhone() }
            } else if model.phase == .running && model.isSimulation {
                Spacer()
                Button("Simulate phone connection") { model.requestPhone() }.buttonStyle(.borderedProminent)
            } else if model.phase == .stopped || model.phase == .failed {
                Spacer()
                Button(model.phase == .failed ? "Restart bridge" : "Start bridge") { model.start() }.buttonStyle(.borderedProminent)
            }
        }.controlSize(.large).disabled(model.busy)
    }
}

/// Asks macOS for Bluetooth access during setup, before the bridge first advertises.
final class BluetoothAccess: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    @Published private(set) var authorization = CBManager.authorization
    @Published private(set) var requesting = false
    private var manager: CBPeripheralManager?
    private var completion: (() -> Void)?
    func refresh() { authorization = CBManager.authorization }
    func request(_ completion: @escaping () -> Void) {
        refresh()
        guard authorization == .notDetermined else { completion(); return }
        self.completion = completion; requesting = true
        manager = CBPeripheralManager(delegate: self, queue: .main, options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        refresh()
        guard authorization != .notDetermined else { return }
        manager?.delegate = nil; manager = nil; requesting = false
        completion?(); completion = nil
    }
}

struct BridgeSettings: View {
    @ObservedObject var desktop: MacDesktopServices
    @ObservedObject var model: MacBridgeModel
    let exportReport: () -> Void
    let runSetup: () -> Void
    @AppStorage("bridge.appearance") private var appearance = "Match Mac"
    @AppStorage("bridge.keepRunning") private var keepRunning = true
    @Environment(\.colorScheme) private var scheme
    private var colors: BridgePalette { BridgePalette(dark: appearance == "Stage" || (appearance == "Match Mac" && scheme == .dark)) }
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "–") (\(info?["CFBundleVersion"] as? String ?? "–"))"
    }
    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { desktop.loginState == .enabled || desktop.loginState == .needsApproval }, set: desktop.setLoginEnabled))
                if let status = desktop.loginDescription { Text(status).foregroundStyle(.secondary) }
                if let error = desktop.loginError { Text(error).foregroundStyle(.red) }
                if desktop.loginState == .needsApproval || desktop.loginError != nil || desktop.loginState == .unavailable {
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle(isOn: $keepRunning) {
                    Text("Keep running when the window closes")
                    Text("Patchbridge stays in the menu bar.")
                }
                Toggle("Show in Dock", isOn: Binding(get: { desktop.showInDock }, set: desktop.setShowInDock))
                Picker("Appearance", selection: $appearance) {
                    ForEach(["Match Mac", "Stage", "Daylight"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented)
                Button("Run setup again…", action: runSetup)
                    .disabled(![.stopped, .failed].contains(model.phase)).help("Stop the bridge to run setup again.")
            }
            Section("Notifications") {
                Toggle("Approval requests and connection problems", isOn: Binding(get: { desktop.notificationsEnabled }, set: desktop.setNotificationsEnabled))
                if desktop.requestingPermission { ProgressView("Waiting for macOS permission…").controlSize(.small) }
                if desktop.permission == .denied {
                    Text("Blocked in System Settings.").foregroundStyle(.secondary)
                    Button("Open System Settings") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
                }
                if let error = desktop.notificationError { Text(error).foregroundStyle(.red) }
            }
            Section("Bluetooth") {
                LabeledContent("iPhones see this Mac as", value: DeviceIdentity.macName)
            }
            Section("Diagnostics") {
                LabeledContent {
                    Button("Export report…", action: exportReport)
                } label: {
                    Text("Reports leave out preset names, values and device IDs. Nothing is sent automatically.").foregroundStyle(.secondary)
                }
            }
            Section("About") {
                LabeledContent("Patchbridge", value: version)
                LabeledContent("Tested with", value: "CorOS 4.1.1")
            }
        }.formStyle(.grouped).tint(colors.signal).frame(width: 500, height: 690)
            .preferredColorScheme(appearance == "Match Mac" ? nil : appearance == "Stage" ? .dark : .light)
            .onAppear { desktop.refresh() }
    }
}

final class Host: NSObject, NSApplicationDelegate {
    private let model = MacBridgeModel()
    private var desktop: MacDesktopServices!
    private var window: NSWindow?
    private var settings: NSWindow?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    func applicationDidFinishLaunching(_ notification: Notification) {
        desktop = MacDesktopServices(login: SystemLoginItem(), notifications: SystemBridgeNotifications())
        desktop.onOpen = { [weak self] in self?.showWindow() }
        desktop.onDockChange = { visible in
            NSApp.setActivationPolicy(visible ? .regular : .accessory)
            NSApp.activate(ignoringOtherApps: true)
        }
        UserDefaults.standard.register(defaults: ["bridge.keepRunning": true])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        for (title, action, key) in [("Open Patchbridge", #selector(showWindow), "0"), ("Settings…", #selector(showSettings), ","), ("Export Troubleshooting Report…", #selector(exportReport), "e")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; appMenu.addItem(item)
        }
        appMenu.addItem(NSMenuItem(title: "Quit Patchbridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        NSApp.mainMenu = menu
        window.title = "Patchbridge"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BridgeWindow(model: model, exportReport: { [weak self] in self?.exportReport() }))
        window.contentMinSize = NSSize(width: 480, height: 700)
        self.window = window
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.target = self; status.button?.action = #selector(togglePopover); statusItem = status
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 560)
        popover.contentViewController = NSHostingController(rootView: BridgeWindow(
            model: model, exportReport: { [weak self] in self?.exportReport() }, compact: true,
            menuActions: [("Open Patchbridge", { [weak self] in self?.showWindow() }),
                          ("Settings…", { [weak self] in self?.showSettings() }),
                          ("Quit", { NSApp.terminate(nil) })]
        ).frame(width: 360, height: 560))
        model.onChange = { [weak self] in guard let self else { return }; self.updateStatus(); self.desktop.stateChanged(self.model) }; updateStatus()
        NSApp.setActivationPolicy(desktop.showInDock ? .regular : .accessory)
        window.center(); showWindow()
    }
    private func updateStatus() {
        let symbol = model.phase == .connected ? "square.grid.3x3.fill" : [.failed, .recovering].contains(model.phase) ? "exclamationmark.triangle" : model.phase == .awaitingApproval ? "person.crop.circle.badge.questionmark" : "square.grid.3x3"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Patchbridge: \(model.title)")
        statusItem?.button?.toolTip = model.title
    }
    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
    @objc private func showWindow() { popover.performClose(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func showSettings() {
        popover.performClose(nil)
        desktop.refresh()
        if settings == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 280), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Settings"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: BridgeSettings(
                desktop: desktop, model: model, exportReport: { [weak self] in self?.exportReport() },
                runSetup: { [weak self] in UserDefaults.standard.set(false, forKey: "bridge.setupComplete"); self?.showWindow() })); settings = panel; panel.center()
        }
        settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func exportReport() {
        showWindow()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Patchbridge-Troubleshooting.json"
        panel.title = "Export Troubleshooting Report"
        panel.message = "Preset contents, names, values and device identifiers are excluded."
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            do { try Diagnostics.shared.export(to: destination) }
            catch {
                let alert = NSAlert(); alert.messageText = "Report could not be saved"
                alert.informativeText = "Choose a writable folder and try again."; alert.beginSheetModal(for: window)
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !UserDefaults.standard.bool(forKey: "bridge.keepRunning") }
    func applicationDidBecomeActive(_ notification: Notification) { desktop?.refresh() }
    func applicationWillTerminate(_ notification: Notification) { desktop?.clearNotification(); model.shutdown() }
}
func verify(_ helper: HelperClient) throws {
    let connected = try helper.request(["operation": "connect"])
    guard connected["status"] as? String == "confirmed",
          let session = connected["session_id"] as? String else { throw BridgeFailure.protocolError }
    let edited = try helper.request(["operation": "set_parameter", "session_id": session, "revision": 0,
                                    "preset_id": "1", "scene": "A", "payload": ["block_id": "amp-1", "parameter_id": "gain", "value": 7.5]])
    guard edited["status"] as? String == "confirmed" else { throw BridgeFailure.protocolError }
    let saved = try helper.request(["operation": "save", "session_id": session, "revision": edited["revision"]!, "preset_id": "1", "scene": "A"])
    guard saved["status"] as? String == "confirmed", let result = saved["result"] as? [String: Any],
          let state = result["state"] as? [String: Any], state["dirty"] as? Bool == false,
          let blocks = state["blocks"] as? [[String: Any]], let scenes = blocks.first?["scenes"] as? [String: [String: Any]],
          let parameters = scenes["A"]?["parameters"] as? [String: Any], parameters["gain"] as? Double == 7.5
    else { throw BridgeFailure.protocolError }
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--export-report" {
    do {
        do {
            let helper = try HelperClient(bundle: .main)
            defer { helper.stop() }
            try verify(helper)
        } catch { Diagnostics.shared.record(.requestFailed, code: "transport_failure") }
        try Diagnostics.shared.export(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("PASS: offline troubleshooting report exported without preset contents")
    } catch { fputs("Report export failed.\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--self-test") {
    do {
        let helper = try HelperClient(bundle: .main)
        defer { helper.stop() }
        try verify(helper)
        print("PASS: bundled isolated Python → simulation connect/edit/save → clean helper shutdown")
    } catch { fputs("Bundled helper check failed: \(error)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let host = Host()
    app.setActivationPolicy(.regular); app.delegate = host
    app.run()
}
