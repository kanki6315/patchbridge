#if DEBUG
import AppKit
import SwiftUI

/// Offline presentation fixture. Never instantiates USB, Bluetooth, helper, or trust storage.
private final class ScreenshotBackend: OfflineBridgeBackend {
    var presentation: MacBridgePresentation
    var state: (MacBridgeModel.Phase, String)?
    var onChange: (() -> Void)?
    func show(_ presentation: MacBridgePresentation, phase: MacBridgeModel.Phase = .connected, detail: String? = nil) {
        self.presentation = presentation
        state = (phase, detail ?? "Connected over Bluetooth and USB. Supported edits are confirmed by QC readback.")
        onChange?()
    }
    var isLive: Bool { true } // Use the ordinary connection presentation, without simulation controls.
    init(_ presentation: MacBridgePresentation, approval: Bool) {
        self.presentation = presentation
        state = approval ? (.awaitingApproval, "Compare this code with the one on Steve’s iPhone before approving.") : (.connected, "Connected over Bluetooth and USB. Supported edits are confirmed by QC readback.")
    }
    func start() throws {}
    func requestPhone() throws {}
    func refresh() throws {}
    func stop() {}
    func interruptHelper() {}
}

enum MacScreenshotPreview {
    static func render(fixture: String, output: String, replay: Bool = false) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(replay ? .regular : .prohibited)
        app.appearance = NSAppearance(named: .darkAqua)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixture))) as! [String: Any]
        let snapshot = root["snapshot"] as! [String: Any]
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("native"), withIntermediateDirectories: true)
        let suiteName = "PatchbridgeScreenshot-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "bridge.setupComplete")
        defaults.set("Stage", forKey: "bridge.appearance")
        defaults.set(true, forKey: "bridge.trustPhone")
        let stories = [
            ("01-usb-connection", "Your Quad Cortex.\nConnected.", "Connect Quad Cortex to your Mac over USB.\nEdit from your iPhone over Bluetooth."),
            ("02-device-approval", "Approve the devices\nyou trust.", "Compare the code and approve your device.\nYou decide who can connect."),
            ("03-multiple-devices", "One Quad Cortex.\niPhone and iPad.", "Connect your iPhone and iPad to the same\nQuad Cortex session."),
            ("04-trusted-devices", "Reconnect\nwith confidence.", "Trusted devices reconnect without a code.\nRevoke access whenever you need.")
        ]
        let manifest = stories.map { ["file": $0.0, "title": $0.1, "subtitle": $0.2] }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("manifest.json"))
        var presentations: [MacBridgePresentation] = []
        for (index, story) in stories.enumerated() {
            let phoneID = UUID(), tabletID = UUID(), trustID = UUID()
            var p = MacBridgePresentation()
            p.macName = "Studio Mac"; p.phoneName = "Steve’s iPhone"
            p.preset = snapshot["name"] as? String; p.scene = snapshot["scene"] as? String
            p.devices = [BridgeDevice(id: phoneID, connection: "preview-phone", name: p.phoneName, state: .connected, trustID: trustID)]
            p.trusted = [TrustedDevice(id: trustID, name: p.phoneName, connected: true)]
            if index == 1 {
                p.devices = []; p.trusted = []; p.preset = nil; p.scene = nil
                p.pendingID = phoneID; p.pendingConnection = "preview-phone"; p.approvalCode = "482 916"
            }
            if index == 2 {
                p.devices.append(BridgeDevice(id: tabletID, connection: "preview-tablet", name: "Maya’s iPad", state: .connected, trustID: tabletID))
                p.trusted.append(TrustedDevice(id: tabletID, name: "Maya’s iPad", connected: true))
            }
            if index == 3 {
                p.trusted.append(TrustedDevice(id: tabletID, name: "Maya’s iPad"))
                p.trusted.append(TrustedDevice(id: UUID(), name: "Alex’s iPhone"))
            }
            presentations.append(p)
            if replay { continue }
            let model = MacBridgeModel(backend: ScreenshotBackend(p, approval: index == 1))
            model.start()
            pump(0.2)
            let host = NSHostingView(rootView: BridgeWindow(model: model, exportReport: {}).defaultAppStorage(defaults))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 890), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Patchbridge"; window.contentView = host
            window.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 890)
            host.layoutSubtreeIfNeeded(); pump(0.8)
            let view = window.contentView!.superview!
            view.layoutSubtreeIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("native/\(story.0).png"))
            model.shutdown(); window.contentView = nil
            print("Rendered \(story.0)")
        }
        if replay {
            let player = FixtureClipPlayer(presentations: presentations, defaults: defaults)
            player.open()
            withExtendedLifetime(player) { app.run() }
        }
    }
    private static func pump(_ duration: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: duration)) }
}
/// Real native window, driven by an offline sequence. No UI is painted into a movie.
private final class FixtureClipPlayer: NSObject {
    let presentations: [MacBridgePresentation]
    let defaults: UserDefaults
    let backend: ScreenshotBackend
    let model: MacBridgeModel
    var window: NSWindow!
    var timers: [Timer] = []
    init(presentations: [MacBridgePresentation], defaults: UserDefaults) {
        self.presentations = presentations; self.defaults = defaults
        backend = ScreenshotBackend(presentations[0], approval: false)
        model = MacBridgeModel(backend: backend)
    }
    func open() {
        model.start()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 890), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Patchbridge"
        window.contentView = NSHostingView(rootView: BridgeWindow(model: model, exportReport: {}).defaultAppStorage(defaults))
        window.appearance = NSAppearance(named: .darkAqua)
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let actions = NSMenu(title: "Patchbridge"); appItem.submenu = actions
        let play = NSMenuItem(title: "Play Recording Sequence", action: #selector(playSequence), keyEquivalent: "r")
        play.target = self; actions.addItem(play)
        actions.addItem(.separator())
        actions.addItem(NSMenuItem(title: "Quit Patchbridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        NSApplication.shared.mainMenu = menu
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    @objc func playSequence() {
        timers.forEach { $0.invalidate() }; timers = []
        // Three seconds to hide recording controls, then five 5.6-second clips.
        let delay = 3.0
        func at(_ second: Double, _ work: @escaping () -> Void) {
            timers.append(Timer.scheduledTimer(withTimeInterval: delay + second, repeats: false) { _ in work() })
        }
        let connected = presentations[0], approval = presentations[1], multiple = presentations[2]
        let trusted = presentations[3]
        backend.show(connected)
        at(0) { self.backend.show(connected) }
        at(5.6) { self.backend.show(approval, phase: .awaitingApproval, detail: "Compare this code with the one on Steve’s iPhone before approving.") }
        at(7.8) { self.backend.show(approval, phase: .approving, detail: "Approving this connection and requesting a snapshot.") }
        at(8.4) { self.backend.show(connected) }
        at(11.2) { self.backend.show(connected) }
        at(13.4) { self.backend.show(multiple) }
        at(16.8) { self.backend.show(connected) }
        at(18.2) { var edited = connected; edited.dirty = true; self.backend.show(edited) }
        at(21.2) { self.backend.show(connected) }
        at(22.4) { self.backend.show(trusted) }
        at(24.4) { self.backend.show(multiple) }
        at(27.9) { self.backend.show(multiple) }
    }
}
#endif
