import ActivityKit
import UIKit
import UserNotifications

/// Mirrors the session into the optional Live Activity, and alerts on drops the user didn't start.
/// The activity doesn't keep Bluetooth alive; background connection support does that.
final class ConnectionActivityController {
    static let showKey = "patchbridge.showConnectionStatus"
    static let alertKey = "patchbridge.alertOnDrop"
    private static let notificationID = "connection-lost"
    private var activity: Activity<ConnectionAttributes>?
    private var last: ConnectionAttributes.ContentState?
    /// A session reached ready since the last intentional disconnect.
    private var live = false
    private var intentional = false
    private(set) var reconnecting = false
    private var lostAt: Date?

    static var supported: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    static var systemEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    private var showStatus: Bool { Self.supported && UserDefaults.standard.bool(forKey: Self.showKey) }
    private var alertOnDrop: Bool { UserDefaults.standard.bool(forKey: Self.alertKey) }

    init() {
        // An activity left by a previous launch no longer reflects a session.
        for stale in Activity<ConnectionAttributes>.activities { Task { await stale.end(nil, dismissalPolicy: .immediate) } }
    }
    func willDisconnect() { intentional = true; reconnecting = false }
    func willReconnect() { reconnecting = true; intentional = false }

    func sync(_ model: PhoneModel) {
        let coordinator = model.coordinator
        if model.demo { live = false; reconnecting = false; intentional = false; end(ended: false); return }
        let status: ConnectionAttributes.ContentState.Status?
        switch coordinator.phase {
        case .ready:
            status = .connected; live = true; reconnecting = false; intentional = false; lostAt = nil
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        case .recovering: status = live ? .qcLost : nil
        case .connecting, .loading: status = reconnecting ? .reconnecting : (live ? last?.status : nil)
        case .awaitingApproval: status = reconnecting ? .approval : nil
        case .failed:
            guard live || reconnecting, !intentional else { return }
            if last?.status != .lost { lostAt = Date() }
            status = .lost; reconnecting = false
        case .disconnected:
            // start() passes through here on its way to connecting; only a user's Disconnect ends the session.
            guard intentional else { return }
            intentional = false; live = false; reconnecting = false
            end(ended: true); return
        }
        guard let status else { return }
        if let current = activity, [.dismissed, .ended].contains(current.activityState) { activity = nil }
        let state = content(status, model)
        if status == .lost, last?.status != .lost, alertOnDrop { alert(state) }
        if !showStatus { if activity != nil { end(ended: false) }; last = state; return }
        guard state != last || activity == nil else { return }
        last = state
        if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        } else if status == .connected, Self.systemEnabled {
            // Requests need the app in the foreground; a session starts there.
            activity = try? Activity.request(attributes: ConnectionAttributes(), content: ActivityContent(state: state, staleDate: nil))
        }
    }

    private func content(_ status: ConnectionAttributes.ContentState.Status, _ model: PhoneModel) -> ConnectionAttributes.ContentState {
        let snapshot = model.coordinator.editor.snapshot
        let scene = snapshot?.scene
        let index = Array("ABCDEFGH").firstIndex(of: scene?.first ?? "A") ?? 0
        let colors = snapshot?.scene_colors
        let defaults = UserDefaults.standard
        let daylight = defaults.bool(forKey: "matchSystem")
            ? UIScreen.main.traitCollection.userInterfaceStyle == .light
            : defaults.string(forKey: "appearance") == "Daylight"
        return .init(status: status, macName: model.coordinator.macName ?? last?.macName ?? "Mac",
                     preset: snapshot?.name ?? last?.preset, scene: scene ?? last?.scene,
                     sceneName: scene == nil ? last?.sceneName : (model.sceneName(index).isEmpty ? nil : model.sceneName(index)),
                     sceneColor: colors?.indices.contains(index) == true ? colors![index] & 0xffffff : (scene == nil ? last?.sceneColor : nil),
                     unsaved: snapshot?.dirty ?? last?.unsaved ?? false, trusted: model.coordinator.trusted || (status == .reconnecting && model.hasTrust),
                     lostAt: lostAt, daylight: daylight)
    }

    private func alert(_ state: ConnectionAttributes.ContentState) {
        let title = "Connection to \(state.macName) lost", body = "Editing is paused. Tap to reconnect."
        if showStatus, let activity {
            Task {
                await activity.update(ActivityContent(state: state, staleDate: nil),
                                      alertConfiguration: AlertConfiguration(title: "\(title)", body: "\(body)", sound: .default))
            }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
    }

    /// The ended state stays briefly so you can see whether edits were left unsaved.
    private func end(ended: Bool) {
        guard let activity else { last = nil; return }
        self.activity = nil
        var final = last
        if ended { final?.status = .ended }
        last = nil
        Task {
            await activity.end(final.map { ActivityContent(state: $0, staleDate: nil) },
                               dismissalPolicy: ended ? .after(Date().addingTimeInterval(15 * 60)) : .immediate)
        }
    }

    #if DEBUG
    /// `--activity <status>` shows a sample activity for design review. No session is involved.
    func preview(_ name: String, daylight: Bool) {
        guard let status = ConnectionAttributes.ContentState.Status(rawValue: name) else { return }
        let state = ConnectionAttributes.ContentState(status: status, macName: "Studio Mac", preset: "Tremonti w Mic", scene: "F", sceneName: "Rhythm",
                                                      sceneColor: 0xff7000, unsaved: true, trusted: true, lostAt: Date(), daylight: daylight)
        activity = try? Activity.request(attributes: ConnectionAttributes(), content: ActivityContent(state: state, staleDate: nil))
    }
    #endif

    /// Asks once, when the alert setting is turned on.
    static func requestAlertPermission(_ completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
