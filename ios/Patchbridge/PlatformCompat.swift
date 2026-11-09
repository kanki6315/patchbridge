#if os(macOS)
import AppKit
import SwiftUI

// The Mac app builds the iPad editor views as they are. These stand-ins cover the few iOS-only
// APIs those views use, so the shared files stay free of per-platform branches.

/// Trackpad haptics stand in for the iPhone's Taptic Engine.
struct UISelectionFeedbackGenerator {
    func selectionChanged() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
}
struct UIImpactFeedbackGenerator {
    enum FeedbackStyle { case light, medium, heavy, soft, rigid }
    init(style: FeedbackStyle) {}
    func impactOccurred() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
}
struct UINotificationFeedbackGenerator {
    enum FeedbackType { case success, warning, error }
    func notificationOccurred(_ type: FeedbackType) { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
}

/// Copy link writes to the Mac's pasteboard.
struct UIPasteboard {
    static var general = UIPasteboard()
    var url: URL? {
        get { NSPasteboard.general.string(forType: .URL).flatMap(URL.init(string:)) }
        nonmutating set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue.absoluteString, forType: .URL) }
        }
    }
}

extension View {
    /// Mac windows have no inline navigation bar title mode.
    func navigationBarTitleDisplayMode(_ mode: NavigationBarItemTitleDisplayModeCompat) -> some View { self }
}
enum NavigationBarItemTitleDisplayModeCompat { case automatic, inline, large }
#endif
