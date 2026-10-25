import SwiftUI

@main
struct PatchbridgeApp: App {
    @StateObject private var editor = PhoneModel()
    @Environment(\.scenePhase) private var phase
    init() { AppearancePrefs.migrate() }
    var body: some Scene {
        WindowGroup {
            EditorView(model: editor)
                .onChange(of: phase) { _, value in
                    if value == .background { editor.background() }
                    else if value == .active { editor.foreground() }
                }
        }
    }
}
