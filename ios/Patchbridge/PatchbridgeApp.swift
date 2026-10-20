import SwiftUI

@main
struct PatchbridgeApp: App {
    @StateObject private var editor = EditorModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            EditorView(model: editor)
                .onChange(of: phase) { _, value in
                    if value == .background { editor.disconnect() }
                }
        }
    }
}
