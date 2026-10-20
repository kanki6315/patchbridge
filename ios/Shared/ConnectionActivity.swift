import ActivityKit
import AppIntents
import Foundation

/// The optional session Live Activity. Compiled into the app and the widget extension.
struct ConnectionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Status: String, Codable, Hashable { case connected, qcLost, lost, reconnecting, approval, ended }
        var status: Status
        var macName: String
        var preset: String?
        var scene: String?
        var sceneName: String?
        /// 0xRRGGBB from the QC; nil when the QC didn't report one.
        var sceneColor: UInt32?
        var unsaved = false
        var trusted = false
        var lostAt: Date?
        /// The app's Stage/Daylight choice. The Dynamic Island always uses Stage.
        var daylight = false
    }
}

/// Live Activity buttons run in the app's process, where the session lives.
enum ConnectionActivityAction { case disconnect, reconnect }
enum ConnectionActivityActions {
    /// Set once by the app at launch; called on the main actor.
    nonisolated(unsafe) static var handler: ((ConnectionActivityAction) -> Void)?
}

struct DisconnectSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Disconnect"
    static let description = IntentDescription("Ends the Patchbridge session with your Mac.")
    static let isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        ConnectionActivityActions.handler?(.disconnect)
        return .result()
    }
}

struct ReconnectSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Reconnect"
    static let description = IntentDescription("Reconnects Patchbridge to the last Mac.")
    static let isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        ConnectionActivityActions.handler?(.reconnect)
        return .result()
    }
}
