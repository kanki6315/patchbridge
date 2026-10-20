import AppKit
import SwiftUI

struct BridgeWindow: View {
    @ObservedObject var model: MacBridgeModel
    let exportReport: () -> Void
    private var active: Bool { model.phase != .stopped && model.phase != .failed }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Patchbridge").font(.system(size: 26, weight: .semibold))
                    Text("Mac bridge").foregroundStyle(.secondary)
                }
                Spacer()
                Label("Simulation", systemImage: "testtube.2").font(.callout).foregroundStyle(.secondary)
            }
            Text("Try the connection and approval flow locally. Bluetooth and USB are off.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.phase == .failed ? "exclamationmark.triangle" : model.phase == .connected ? "checkmark.circle" : "network")
                    .font(.title2).foregroundStyle(model.phase == .failed ? Color.orange : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.title).font(.headline)
                    Text(model.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
            }
            HStack(spacing: 10) {
                if !active {
                    Button(model.phase == .failed ? "Restart bridge" : "Start bridge") { model.start() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Stop bridge") { model.stop() }.disabled(model.phase == .stopping)
                }
                Spacer()
                if model.phase == .running {
                    Button("Simulate phone connection") { model.requestPhone() }.disabled(model.busy)
                }
            }
            if model.phase == .awaitingApproval || model.phase == .approving || model.phase == .connected {
                Divider()
                HStack {
                    Label("Simulated iPhone", systemImage: "iphone")
                    Spacer()
                    Text(model.phase == .connected ? "Approved" : "Awaiting approval")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    if model.phase == .connected {
                        Button("Disconnect phone") { model.disconnectPhone() }
                        Spacer()
                        Button("Check connection") { model.refresh() }
                    } else {
                        Button("Deny") { model.disconnectPhone() }
                        Spacer()
                        Button("Approve connection") { model.approve() }.buttonStyle(.borderedProminent)
                    }
                }.disabled(model.busy)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Button("Export report…", action: exportReport)
                    .help("Export recent diagnostic events without preset contents or identifiers")
                Spacer()
                if model.phase == .connected {
                    Button("Simulate helper failure") { model.simulateFailure() }.disabled(model.busy)
                }
            }
            Text("Reports exclude preset contents, names, values, and device identifiers.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(minWidth: 500, maxWidth: .infinity, minHeight: 440, maxHeight: .infinity, alignment: .topLeading)
    }
}

final class Host: NSObject, NSApplicationDelegate {
    private let model = MacBridgeModel()
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let export = NSMenuItem(title: "Export Troubleshooting Report…", action: #selector(exportReport), keyEquivalent: "e")
        export.target = self; appMenu.addItem(export)
        appMenu.addItem(NSMenuItem(title: "Quit Patchbridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        NSApp.mainMenu = menu
        window.title = "Patchbridge"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BridgeWindow(model: model, exportReport: { [weak self] in self?.exportReport() }))
        window.contentMinSize = NSSize(width: 500, height: 520)
        self.window = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Patchbridge-Troubleshooting.json"
        panel.title = "Export Troubleshooting Report"
        panel.message = "Includes recent lifecycle events and error codes. Preset contents, names, values, device identifiers, and file paths are excluded."
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
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
