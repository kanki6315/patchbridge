import SwiftUI

@main
struct PatchbridgeWatchApp: App {
    @StateObject private var model = WatchModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            WatchRootView(model: model)
                .onChange(of: phase) { _, value in model.setActive(value == .active) }
                .task {
                    model.setActive(phase == .active)
                    while !Task.isCancelled {
                        model.tick()
                        do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                    }
                }
        }
    }
}
