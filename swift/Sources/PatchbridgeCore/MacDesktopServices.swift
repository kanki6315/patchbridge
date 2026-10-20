#if os(macOS)
import AppKit
import Combine
import ServiceManagement
import UserNotifications

enum LoginItemState { case disabled, enabled, needsApproval, unavailable }
protocol LoginItemManaging: AnyObject {
    var state: LoginItemState { get }
    func setEnabled(_ enabled: Bool) throws
}
final class SystemLoginItem: LoginItemManaging {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .disabled
        default: return .unavailable
        }
    }
    func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}

enum NotificationPermission { case notAsked, allowed, denied }
protocol BridgeNotifying: AnyObject {
    var onOpen: (() -> Void)? { get set }
    func permission(_ completion: @escaping (NotificationPermission) -> Void)
    func requestPermission(_ completion: @escaping (Bool) -> Void)
    func post(id: String, title: String, body: String, completion: @escaping (Bool) -> Void)
    func remove(ids: [String])
}
final class SystemBridgeNotifications: NSObject, BridgeNotifying, UNUserNotificationCenterDelegate {
    var onOpen: (() -> Void)?
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: "bridge.review", actions: [
            UNNotificationAction(identifier: "review", title: "Open Patchbridge", options: [.foreground])
        ], intentIdentifiers: [])])
        // Nothing from a previous process can represent a current approval request.
        center.removeAllPendingNotificationRequests(); center.removeAllDeliveredNotifications()
    }
    func permission(_ completion: @escaping (NotificationPermission) -> Void) {
        center.getNotificationSettings { settings in
            let result: NotificationPermission
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: result = .allowed
            case .notDetermined: result = .notAsked
            default: result = .denied
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert]) { allowed, _ in DispatchQueue.main.async { completion(allowed) } }
    }
    func post(id: String, title: String, body: String, completion: @escaping (Bool) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.categoryIdentifier = "bridge.review"
        // No preset contents, session tokens or approval codes in Notification Center.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            DispatchQueue.main.async { completion(error == nil) }
        }
    }
    func remove(ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in self?.onOpen?(); completionHandler() }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async {
            completionHandler(NSApp.keyWindow?.isVisible == true ? [] : [.banner, .list])
        }
    }
}

/// Main-queue owner for OS settings. Injectable services keep tests from changing login items or permission.
final class MacDesktopServices: ObservableObject {
    @Published private(set) var loginState: LoginItemState = .disabled
    @Published private(set) var loginError: String?
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var permission: NotificationPermission = .notAsked
    @Published private(set) var requestingPermission = false
    @Published private(set) var notificationError: String?
    @Published private(set) var showInDock: Bool
    var onDockChange: ((Bool) -> Void)?
    var onOpen: (() -> Void)? { didSet { notifications.onOpen = onOpen } }
    private let login: LoginItemManaging
    private let notifications: BridgeNotifying
    private let defaults: UserDefaults
    private var permissionEpoch = UUID()
    private var notificationID: String?
    private var phase: MacBridgeModel.Phase = .stopped
    private var requestCode = ""
    init(login: LoginItemManaging, notifications: BridgeNotifying, defaults: UserDefaults = .standard) {
        self.login = login; self.notifications = notifications; self.defaults = defaults
        notificationsEnabled = defaults.bool(forKey: "bridge.notifications")
        showInDock = defaults.object(forKey: "bridge.showInDock") as? Bool ?? true
        refresh()
    }
    func refresh() {
        loginState = login.state
        let epoch = permissionEpoch
        notifications.permission { [weak self] status in
            guard let self, self.permissionEpoch == epoch else { return }
            if status == .allowed && self.permission == .denied { self.notificationError = nil }
            self.permission = status
            if status == .denied { self.clearNotification() }
        }
    }
    func setLoginEnabled(_ enabled: Bool) {
        loginError = nil
        do { try login.setEnabled(enabled) }
        catch { loginError = "macOS couldn’t change the login item. Check Login Items in System Settings." }
        loginState = login.state // Never claim the preference took effect before macOS confirms it.
    }
    func setShowInDock(_ enabled: Bool) {
        showInDock = enabled; defaults.set(enabled, forKey: "bridge.showInDock"); onDockChange?(enabled)
    }
    func setNotificationsEnabled(_ enabled: Bool) {
        permissionEpoch = UUID(); requestingPermission = false; notificationError = nil
        notificationsEnabled = enabled; defaults.set(enabled, forKey: "bridge.notifications")
        if !enabled { clearNotification(); return }
        let epoch = permissionEpoch
        requestingPermission = true
        notifications.requestPermission { [weak self] allowed in
            guard let self, self.permissionEpoch == epoch else { return }
            self.requestingPermission = false; self.permission = allowed ? .allowed : .denied
            if !allowed { self.clearNotification(); self.notificationError = "Notifications are unavailable. You can allow them in System Settings." }
        }
    }
    func stateChanged(_ model: MacBridgeModel) {
        stateChanged(phase: model.phase, approvalCode: model.presentation.approvalCode, simulated: model.isSimulation)
    }
    func stateChanged(phase next: MacBridgeModel.Phase, approvalCode: String = "", simulated: Bool = true) {
        guard next != phase || (next == .awaitingApproval && approvalCode != requestCode) else { return }
        phase = next; requestCode = approvalCode
        clearNotification()
        guard notificationsEnabled, permission == .allowed else { return }
        let title: String, body: String
        switch next {
        case .awaitingApproval:
            title = simulated ? "Simulated iPhone approval requested" : "iPhone approval requested"
            body = "Open Patchbridge to compare the current approval code."
        case .recovering:
            title = simulated ? "Simulated QC connection interrupted" : "QC connection interrupted"
            body = "Editing is paused while the bridge reloads state."
        case .failed:
            title = "Patchbridge needs attention"
            body = "Open Patchbridge to restart the bridge. Fresh phone approval is required."
        default: return
        }
        let id = UUID().uuidString; notificationID = id
        notifications.post(id: id, title: title, body: body) { [weak self] success in
            guard let self else { return }
            guard self.notificationID == id, self.notificationsEnabled else {
                self.notifications.remove(ids: [id]); return
            }
            if !success { self.notificationError = "The notification couldn’t be delivered. Check System Settings." }
        }
    }
    func clearNotification() {
        if let id = notificationID { notifications.remove(ids: [id]) }
        notificationID = nil
    }
    /// Only states that need the user's attention have a description.
    var loginDescription: String? {
        switch loginState {
        case .needsApproval: return "Allow Patchbridge in System Settings → Login Items."
        case .unavailable: return "Login registration is unavailable for this copy of the app."
        case .enabled, .disabled: return nil
        }
    }
}
#endif
