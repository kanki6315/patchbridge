import XCTest
@testable import PatchbridgeCore

private final class FakeLoginItem: LoginItemManaging {
    var state: LoginItemState = .disabled
    var calls = [Bool]()
    var fail = false
    var approvalRequired = false
    func setEnabled(_ enabled: Bool) throws {
        calls.append(enabled)
        if fail { throw BridgeFailure.disconnected }
        state = enabled ? (approvalRequired ? .needsApproval : .enabled) : .disabled
    }
}
private final class FakeNotifications: BridgeNotifying {
    var onOpen: (() -> Void)?
    var status: NotificationPermission = .notAsked
    var permissionRequests = 0
    var requestCompletion: ((Bool) -> Void)?
    var deliveries = [(id: String, title: String, completion: (Bool) -> Void)]()
    var removed = [String]()
    func permission(_ completion: @escaping (NotificationPermission) -> Void) { completion(status) }
    func requestPermission(_ completion: @escaping (Bool) -> Void) { permissionRequests += 1; requestCompletion = completion }
    func post(id: String, title: String, body: String, completion: @escaping (Bool) -> Void) { deliveries.append((id, title, completion)) }
    func remove(ids: [String]) { removed += ids }
}
final class MacDesktopServicesTests: XCTestCase {
    private func make(_ login: FakeLoginItem, _ notifications: FakeNotifications) -> MacDesktopServices {
        let name = "patchbridge.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return MacDesktopServices(login: login, notifications: notifications, defaults: defaults)
    }
    func testDefaultsDoNotRegisterOrRequestPermissionAndDockCanBeRestored() {
        let login = FakeLoginItem(), notifications = FakeNotifications()
        let model = make(login, notifications)
        XCTAssertFalse(model.notificationsEnabled); XCTAssertTrue(model.showInDock)
        XCTAssertEqual(notifications.permissionRequests, 0); XCTAssertTrue(login.calls.isEmpty)
        var policies = [Bool](); model.onDockChange = { policies.append($0) }
        model.setShowInDock(false); model.setShowInDock(true)
        XCTAssertEqual(policies, [false, true])
    }
    func testLoginUsesActualSystemStateAndReportsDenial() {
        let login = FakeLoginItem(); let model = make(login, FakeNotifications())
        login.approvalRequired = true; model.setLoginEnabled(true)
        XCTAssertEqual(model.loginState, .needsApproval)
        model.setLoginEnabled(false); XCTAssertEqual(model.loginState, .disabled)
        login.fail = true; model.setLoginEnabled(true)
        XCTAssertEqual(model.loginState, .disabled); XCTAssertNotNil(model.loginError)
        login.state = .enabled; model.refresh(); XCTAssertEqual(model.loginState, .enabled)
    }
    func testLatePermissionCallbackCannotReenableNotifications() {
        let n = FakeNotifications(); let model = make(FakeLoginItem(), n)
        model.setNotificationsEnabled(true)
        XCTAssertTrue(model.requestingPermission)
        model.setNotificationsEnabled(false); n.requestCompletion?(true)
        XCTAssertFalse(model.notificationsEnabled); XCTAssertFalse(model.requestingPermission)
        model.stateChanged(phase: .awaitingApproval, approvalCode: "ABC·DEF")
        XCTAssertTrue(n.deliveries.isEmpty)
    }
    func testDeniedPermissionHasFallbackAndDoesNotPost() {
        let n = FakeNotifications(); let model = make(FakeLoginItem(), n)
        model.setNotificationsEnabled(true); n.requestCompletion?(false)
        XCTAssertEqual(model.permission, .denied); XCTAssertNotNil(model.notificationError)
        model.stateChanged(phase: .failed); XCTAssertTrue(n.deliveries.isEmpty)
        n.status = .allowed; model.refresh()
        XCTAssertEqual(model.permission, .allowed); XCTAssertNil(model.notificationError)
    }
    func testNotificationsAreDeduplicatedWithdrawnAndLateDeliveryIsRemoved() {
        let n = FakeNotifications(); let model = make(FakeLoginItem(), n)
        model.setNotificationsEnabled(true); n.requestCompletion?(true)
        model.stateChanged(phase: .awaitingApproval, approvalCode: "ABC·DEF")
        model.stateChanged(phase: .awaitingApproval, approvalCode: "ABC·DEF")
        XCTAssertEqual(n.deliveries.count, 1)
        let old = n.deliveries[0]
        model.stateChanged(phase: .connected)
        old.completion(true)
        XCTAssertEqual(n.removed.filter { $0 == old.id }.count, 2)
        model.stateChanged(phase: .recovering); model.stateChanged(phase: .recovering)
        XCTAssertEqual(n.deliveries.count, 2)
        model.setNotificationsEnabled(false)
        XCTAssertTrue(n.removed.contains(n.deliveries[1].id))
        var opened = false; model.onOpen = { opened = true }; n.onOpen?()
        XCTAssertTrue(opened) // Opening a stale notification can only reveal current UI.
    }
    func testDeliveryFailureIsVisible() {
        let n = FakeNotifications(); let model = make(FakeLoginItem(), n)
        model.setNotificationsEnabled(true); n.requestCompletion?(true)
        model.stateChanged(phase: .failed); n.deliveries.first?.completion(false)
        XCTAssertNotNil(model.notificationError)
    }
}
