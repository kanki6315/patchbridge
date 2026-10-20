import SwiftUI

extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}
struct PhoneTheme {
    let daylight: Bool
    var ground: Color { Color(hex: daylight ? 0xf7f7f5 : 0x0d0e0a) }
    var surface: Color { Color(hex: daylight ? 0xffffff : 0x161612) }
    var raised: Color { Color(hex: daylight ? 0xe9e9e5 : 0x24241f) }
    var ink: Color { Color(hex: daylight ? 0x161611 : 0xf2f2ee) }
    var muted: Color { Color(hex: daylight ? 0x555650 : 0xb1b2ab) }
    var line: Color { Color(hex: daylight ? 0xd1d1cd : 0x2e2e29) }
    var signal: Color { Color(hex: daylight ? 0x5c6400 : 0xd1e14a) }
    var signalInk: Color { Color(hex: daylight ? 0xffffff : 0x161802) }
    var caution: Color { Color(hex: daylight ? 0x9d5300 : 0xffc469) }
    var danger: Color { Color(hex: daylight ? 0xba2c25 : 0xff9683) }
}
struct BlockCategory {
    let code: String
    let color: Color
    let darkInk: Bool
    func arc(daylight: Bool) -> Color {
        let shades: [String: UInt32] = daylight
            ? ["CMP": 0x267549, "CAP": 0xa94350, "DRV": 0xa35b08, "AMP": 0xc02b29, "CAB": 0x765440, "MOD": 0x963a90, "DLY": 0x176faa, "REV": 0x267987, "WAH": 0x006d74, "PIT": 0x6550b0, "UTL": 0x66675f]
            : ["CMP": 0x62c797, "CAP": 0xec9ca3, "DRV": 0xffb65c, "AMP": 0xf27870, "CAB": 0xc49c82, "MOD": 0xd88ad2, "DLY": 0x72baf1, "REV": 0x88dfec, "WAH": 0x55c3c7, "PIT": 0xad9ce9, "UTL": 0xb1b2ab]
        return Color(hex: shades[code] ?? 0x86877f)
    }
    init(_ name: String) {
        let n = name.lowercased()
        let spec: (String, UInt32, Bool)
        if n.contains("compress") || n.contains("dynamics") { spec = ("CMP", 0x49af7e, true) }
        else if n.contains("capture") { spec = ("CAP", 0xe5848c, true) }
        else if n.contains("overdrive") || n.contains("distortion") { spec = ("DRV", 0xf59926, true) }
        else if n.contains("cab") { spec = ("CAB", 0x81614f, false) }
        else if n.contains("amp") { spec = ("AMP", 0xd02c2a, false) }
        else if n.contains("modulation") || n.contains("chorus") { spec = ("MOD", 0xb249ac, false) }
        else if n.contains("delay") { spec = ("DLY", 0x46a6ef, true) }
        else if n.contains("reverb") { spec = ("REV", 0x79d4e4, true) }
        else if n.contains("wah") || n.contains("filter") { spec = ("WAH", 0x007c84, false) }
        else if n.contains("pitch") { spec = ("PIT", 0x735cc7, false) }
        else { spec = ("UTL", 0x86877f, true) }
        code = spec.0; color = Color(hex: spec.1); darkInk = spec.2
    }
}
struct GlassSurface: ViewModifier {
    let theme: PhoneTheme
    var radius: CGFloat = 24
    @Environment(\.accessibilityReduceTransparency) private var solid
    func body(content: Content) -> some View {
        if solid { content.background(theme.raised, in: RoundedRectangle(cornerRadius: radius)) }
        else if #available(iOS 26, *) { content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius)) }
        else { content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius)) }
    }
}
extension View {
    @ViewBuilder func parameterMaterial(_ theme: PhoneTheme, enabled: Bool) -> some View {
        if enabled { phoneGlass(theme, radius: 18) } else { self }
    }
    func phoneGlass(_ theme: PhoneTheme, radius: CGFloat = 24) -> some View { modifier(GlassSurface(theme: theme, radius: radius)) }
}
struct PrimaryButton: View {
    let title: String
    let theme: PhoneTheme
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 17) }
            .foregroundStyle(theme.signalInk).background(theme.signal, in: Capsule())
    }
}
