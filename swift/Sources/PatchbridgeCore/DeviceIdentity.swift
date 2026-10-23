import Foundation
#if os(iOS)
import UIKit
#endif

/// Display labels only. Authorization is always bound to the transport and full token.
public enum DeviceIdentity {
    public static func name(_ value: String?, fallback: String) -> String {
        let clean = (value ?? "").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && ![0x202A, 0x202B, 0x202D, 0x202E, 0x202C, 0x2066, 0x2067, 0x2068, 0x2069].contains(Int($0.value))
        }.map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallback : String(clean.prefix(64))
    }
    public static var phoneName: String {
        name(UserDefaults.standard.string(forKey: "patchbridge.phoneName"), fallback: localName)
    }
    /// What this device is called until the player renames it: the system's name, so an iPad joins as "iPad".
    public static var localName: String {
        #if os(iOS)
        return name(UIDevice.current.name, fallback: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")
        #else
        return "iPhone"
        #endif
    }
    public static var macName: String {
        #if os(macOS)
        return name(Foundation.Host.current().localizedName, fallback: "Mac")
        #else
        return "Mac"
        #endif
    }
    public static func approvalCode(_ token: String) -> String {
        let digits = token.replacingOccurrences(of: "-", with: "").uppercased()
        return String(digits.prefix(3)) + "·" + String(digits.dropFirst(3).prefix(3))
    }
}
