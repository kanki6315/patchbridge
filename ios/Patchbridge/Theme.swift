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
    /// Bottom buttons float over scrolling content with no bar behind them. A note beside one
    /// carries its own glass so it stays readable over whatever scrolls under it.
    func floatingNote(_ theme: PhoneTheme) -> some View { padding(.horizontal, 12).padding(.vertical, 8).phoneGlass(theme, radius: 16) }
    /// A floating button's dimmed state, on a solid capsule so content never shows through it.
    func floatingDimmed(_ dimmed: Bool, _ theme: PhoneTheme) -> some View {
        disabled(dimmed).opacity(dimmed ? 0.45 : 1).background(theme.ground, in: Capsule())
    }
    @ViewBuilder func parameterMaterial(_ theme: PhoneTheme, enabled: Bool) -> some View {
        if enabled { phoneGlass(theme, radius: 18) } else { self }
    }
    func phoneGlass(_ theme: PhoneTheme, radius: CGFloat = 24) -> some View { modifier(GlassSurface(theme: theme, radius: radius)) }
    /// The save confirmation. iOS 26 draws it as a popover pointing at the view it's attached to,
    /// so attach it to the Save button itself, never to the screen around it.
    func saveConfirmation(isPresented: Binding<Bool>, demo: Bool, confirm: @escaping () -> Void) -> some View {
        confirmationDialog(demo ? "Save this demo preset?" : "Save on the Quad Cortex?", isPresented: isPresented, titleVisibility: .visible) {
            Button(demo ? "Save demo preset" : "Save preset", action: confirm)
        } message: { Text(demo ? "Changes stay in this demo until you leave it." : "This replaces the saved values of the current preset on the QC.") }
    }
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

/// The Patch Cable "pb" mark from docs/design/brand/patch-cable.svg, drawn in the current foreground style.
struct PatchCableMark: View {
    private static let cable = "M5 182V123C5 90 24 74 57 74H108C133 74 147 88 147 113V132C147 139 152 139 159 141L168 144Q174 146 174 138V70H203V77H249C278 77 294 92 294 119V139C294 167 278 183 250 183H204C186 183 174 177 161 165L155 160Q149 155 142 158C134 175 120 183 100 183H54C35 183 35 155 54 155H100C112 155 119 148 119 137V116C119 108 114 104 105 104H57C42 104 35 111 35 124V182ZM203 105V149Q203 155 210 155H249C259 155 265 149 265 139V120C265 110 260 105 249 105Z"
    private static let jacks = "M10 211H29V227H10Z M13 231H26L30 237Q30 241 25 245Q20 249 15 245L9 240Q7 236 13 231Z M179 21H198V41H179Z M181 1H194L199 7Q200 11 196 14V17H180V14Q175 11 178 7Z"

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 300, size.height / 250)
            context.translateBy(x: (size.width - 300 * scale) / 2, y: (size.height - 250 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.fill(Self.path(Self.cable), with: .foreground, style: FillStyle(eoFill: true))
            var parts = Self.path(Self.jacks)
            parts.addRoundedRect(in: CGRect(x: 1, y: 181, width: 37, height: 26), cornerSize: CGSize(width: 3, height: 3))
            parts.addRoundedRect(in: CGRect(x: 169, y: 45, width: 38, height: 27), cornerSize: CGSize(width: 3, height: 3))
            context.fill(parts, with: .foreground)
        }
    }

    /// Parses the absolute M/L/H/V/C/Q/Z commands the mark uses.
    private static func path(_ data: String) -> Path {
        var tokens: [String] = []
        var current = ""
        for ch in data {
            if ch.isLetter {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(ch))
            } else if ch == " " || ch == "," {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else { current.append(ch) }
        }
        if !current.isEmpty { tokens.append(current) }
        var path = Path()
        var i = 0
        var point = CGPoint.zero
        func next() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        while i < tokens.count {
            let command = tokens[i]; i += 1
            switch command {
            case "M": point = CGPoint(x: next(), y: next()); path.move(to: point)
            case "L": point = CGPoint(x: next(), y: next()); path.addLine(to: point)
            case "H": point.x = next(); path.addLine(to: point)
            case "V": point.y = next(); path.addLine(to: point)
            case "C":
                let c1 = CGPoint(x: next(), y: next()), c2 = CGPoint(x: next(), y: next())
                point = CGPoint(x: next(), y: next()); path.addCurve(to: point, control1: c1, control2: c2)
            case "Q":
                let c = CGPoint(x: next(), y: next())
                point = CGPoint(x: next(), y: next()); path.addQuadCurve(to: point, control: c)
            default: path.closeSubpath()
            }
        }
        return path
    }
}

/// The Patch Cable mark in Signal beside the Patchbridge wordmark, as on the Mac window and the website.
struct Wordmark: View {
    let theme: PhoneTheme
    @ScaledMetric(relativeTo: .largeTitle) private var markHeight: CGFloat = 36
    var body: some View {
        HStack(spacing: 12) {
            PatchCableMark().foregroundStyle(theme.signal).frame(width: markHeight * 1.2, height: markHeight)
            Text("Patchbridge").font(.largeTitle.bold()).tracking(-0.4)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Patchbridge").accessibilityAddTraits(.isHeader)
    }
}

/// The device's own name for UI copy: iPad layouts say "iPad" where iPhone ones say "iPhone".
var deviceName: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

struct AppearanceSettings: View {
    /// The active theme, which already reflects "Match iPhone appearance".
    let theme: PhoneTheme
    @AppStorage("appearance") private var appearance = "Stage"
    @AppStorage("matchSystem") private var matchSystem = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Appearance").font(.largeTitle.bold())
                let cards = ForEach(["Stage", "Daylight"], id: \.self) { card($0) }
                if dynamicTypeSize.isAccessibilitySize { VStack(spacing: 12) { cards } } else { HStack(alignment: .top, spacing: 12) { cards } }
                Toggle("Match \(deviceName) appearance", isOn: $matchSystem)
                    .padding(.horizontal, 16).frame(minHeight: 56)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.line))
                Text("Block colors").font(.headline).padding(.top, 4)
                LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                    ForEach(["Dynamics", "Overdrive", "Amp", "Cab", "Modulation", "Delay", "Reverb", "Wah", "Capture", "Pitch", "Utility"], id: \.self) { name in
                        let category = BlockCategory(name)
                        HStack(spacing: 10) {
                            Text(category.code).font(.caption2.bold()).frame(width: 44, height: 28)
                                .foregroundStyle(category.darkInk ? Color(hex: 0x161611) : .white)
                                .background(category.color, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityHidden(true)
                            Text(name).font(.subheadline)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("Scene colors always come from your QC.").font(.footnote).foregroundStyle(theme.muted)
            }
        }.scrollClipDisabled()
    }
    private func card(_ name: String) -> some View {
        let preview = PhoneTheme(daylight: name == "Daylight")
        let active = preview.daylight == theme.daylight
        return Button { appearance = name; matchSystem = false } label: {
            VStack(alignment: .leading, spacing: 10) {
                miniature(preview)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.headline)
                        Text(active && matchSystem ? "Following \(deviceName)" : (preview.daylight ? "Bright rooms" : "Dim rooms, stages"))
                            .font(.caption).foregroundStyle(theme.muted)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: active ? "checkmark.circle.fill" : "circle").font(.title3)
                        .foregroundStyle(active ? theme.signal : theme.line)
                }.padding(.horizontal, 4)
            }.padding(8).frame(maxWidth: .infinity)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(active ? theme.signal : theme.line, lineWidth: active ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).accessibilityIdentifier("theme-\(name)")
            .accessibilityValue(appearance == name && !matchSystem ? "Selected" : (active ? "Following \(deviceName)" : "Not selected"))
    }
    /// The overview in that theme, drawn with the demo preset.
    private func miniature(_ preview: PhoneTheme) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Capsule().fill(preview.raised).frame(width: 38, height: 9)
            Text(DemoFixture.name).font(.system(size: 13, weight: .bold)).foregroundStyle(preview.ink).lineLimit(1)
            HStack(spacing: 4) {
                ForEach(DemoFixture.sceneColors.indices, id: \.self) { index in
                    Circle().fill(DemoFixture.sceneColors[index]).frame(width: 6, height: 6)
                        .overlay(Circle().stroke(preview.daylight ? preview.ink : .clear, lineWidth: 0.75))
                }
            }
            DemoGrid(theme: preview, cell: 10, codes: false).padding(4).background(preview.surface, in: RoundedRectangle(cornerRadius: 7))
            Capsule().fill(preview.signal).frame(height: 14)
                .overlay(Text("Save").font(.system(size: 8, weight: .bold)).foregroundStyle(preview.signalInk))
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(preview.ground, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(preview.line))
            .accessibilityHidden(true)
    }
}
