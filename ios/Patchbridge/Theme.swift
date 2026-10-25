import SwiftUI

extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}
/// The active theme in its resolved mode. Caution and danger follow the mode, not the theme.
struct PhoneTheme {
    let id: ThemeID
    let daylight: Bool
    var highContrast = false
    /// Carried so views redraw when the block table changes; `BlockCategory` reads the same setting.
    var blocks = BlockPalette.active
    init(_ id: ThemeID = .stage, daylight: Bool, highContrast: Bool = false, blocks: BlockPalette = .active) {
        self.id = id; self.daylight = daylight; self.highContrast = highContrast; self.blocks = blocks
    }
    private var tokens: ThemeID.Tokens { id.tokens(daylight: daylight, highContrast: highContrast) }
    var ground: Color { Color(hex: tokens.ground) }
    var surface: Color { Color(hex: tokens.surface) }
    var raised: Color { Color(hex: tokens.raised) }
    var ink: Color { Color(hex: tokens.ink) }
    var muted: Color { Color(hex: tokens.muted) }
    var line: Color { Color(hex: tokens.line) }
    var signal: Color { Color(hex: tokens.signal) }
    var signalInk: Color { Color(hex: tokens.signalInk) }
    var caution: Color { Color(hex: daylight ? 0x9d5300 : 0xffc469) }
    var danger: Color { Color(hex: daylight ? 0xba2c25 : 0xff9683) }
    /// Hairlines are 2pt in high contrast.
    var hairline: CGFloat { highContrast ? 2 : 1 }
}

enum AppearanceKey {
    static let theme = "theme", mode = "appearanceMode", blocks = "blockColors", highContrast = "highContrast"
}
enum AppearanceMode: String, CaseIterable {
    case dark = "Dark", light = "Light", auto = "Auto"
    func daylight(systemLight: Bool) -> Bool { self == .auto ? systemLight : self == .light }
}
enum AppearancePrefs {
    /// Moves the old single Stage/Daylight choice to Stage in the matching mode, once.
    static func migrate(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: "appearance") != nil || defaults.object(forKey: "matchSystem") != nil else { return }
        if defaults.string(forKey: AppearanceKey.mode) == nil {
            let mode: AppearanceMode = defaults.bool(forKey: "matchSystem") ? .auto
                : (defaults.string(forKey: "appearance") == "Daylight" ? .light : .dark)
            defaults.set(mode.rawValue, forKey: AppearanceKey.mode)
        }
        defaults.removeObject(forKey: "appearance")
        defaults.removeObject(forKey: "matchSystem")
    }
    /// The saved theme and resolved mode, for code outside the view tree (the Live Activity).
    static func current(systemLight: Bool, _ defaults: UserDefaults = .standard) -> (theme: ThemeID, daylight: Bool) {
        let theme = ThemeID(rawValue: defaults.string(forKey: AppearanceKey.theme) ?? "") ?? .stage
        let mode = AppearanceMode(rawValue: defaults.string(forKey: AppearanceKey.mode) ?? "") ?? .dark
        return (theme, mode.daylight(systemLight: systemLight))
    }
}

/// Which colors fill the blocks. QC Match only swaps this table; scene colors never change.
enum BlockPalette: String, CaseIterable {
    case patchbridge = "Patchbridge", qcMatch = "QC Match"
    /// QC Match's colors are placeholders until they're sampled from a Quad Cortex, so only
    /// debug builds offer it.
    static var available: [BlockPalette] {
        #if DEBUG
        allCases
        #else
        [.patchbridge]
        #endif
    }
    static var active: BlockPalette {
        let saved = BlockPalette(rawValue: UserDefaults.standard.string(forKey: AppearanceKey.blocks) ?? "") ?? .patchbridge
        return available.contains(saved) ? saved : .patchbridge
    }
    /// Fill and whether it takes dark ink, for a category code.
    func fill(_ code: String) -> (UInt32, Bool) {
        switch self {
        case .patchbridge:
            let table: [String: (UInt32, Bool)] = ["CMP": (0x49af7e, true), "CAP": (0xe5848c, true), "DRV": (0xf59926, true), "CAB": (0x81614f, false),
                                                   "AMP": (0xd02c2a, false), "MOD": (0xb249ac, false), "DLY": (0x46a6ef, true), "REV": (0x79d4e4, true),
                                                   "WAH": (0x007c84, false), "PIT": (0x735cc7, false)]
            return table[code] ?? (0x86877f, true)
        case .qcMatch:
            let table: [String: (UInt32, Bool)] = ["CMP": (0x3f9b4f, true), "CAP": (0xe07f86, true), "DRV": (0xe8c22a, true), "CAB": (0x8a6a3c, false),
                                                   "AMP": (0xc8341f, false), "MOD": (0x9b4fd0, false), "DLY": (0x2f6fd0, false), "REV": (0x5ab7c9, true),
                                                   "WAH": (0x1f7a70, false), "PIT": (0x6b5bd6, false)]
            return table[code] ?? (0x86877f, true)
        }
    }
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
    init(_ name: String, palette: BlockPalette = .active) {
        let n = name.lowercased()
        if n.contains("compress") || n.contains("dynamics") { code = "CMP" }
        else if n.contains("capture") { code = "CAP" }
        else if n.contains("overdrive") || n.contains("distortion") { code = "DRV" }
        else if n.contains("cab") { code = "CAB" }
        else if n.contains("amp") { code = "AMP" }
        else if n.contains("modulation") || n.contains("chorus") { code = "MOD" }
        else if n.contains("delay") { code = "DLY" }
        else if n.contains("reverb") { code = "REV" }
        else if n.contains("wah") || n.contains("filter") { code = "WAH" }
        else if n.contains("pitch") { code = "PIT" }
        else { code = "UTL" }
        let fill = palette.fill(code)
        color = Color(hex: fill.0); darkInk = fill.1
    }
}
struct GlassSurface: ViewModifier {
    let theme: PhoneTheme
    var radius: CGFloat = 24
    @Environment(\.accessibilityReduceTransparency) private var solid
    func body(content: Content) -> some View {
        // High contrast never lets content show through.
        if theme.highContrast {
            content.background(theme.raised, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(theme.line, lineWidth: theme.hairline))
        }
        else if solid { content.background(theme.raised, in: RoundedRectangle(cornerRadius: radius)) }
        else if #available(iOS 26, *) { content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius)) }
        else { content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius)) }
    }
}
extension View {
    /// High contrast outlines every filled block so its edge never depends on its hue.
    @ViewBuilder func blockOutline(_ theme: PhoneTheme, cornerRadius: CGFloat, filled: Bool = true) -> some View {
        if theme.highContrast && filled {
            overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(theme.ink, lineWidth: 2))
        } else { self }
    }
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
    /// The active theme, already resolved for mode and contrast.
    let theme: PhoneTheme
    @AppStorage(AppearanceKey.theme) private var themeID = ThemeID.stage
    @AppStorage(AppearanceKey.mode) private var mode = AppearanceMode.dark
    @AppStorage(AppearanceKey.highContrast) private var highContrast = false
    @AppStorage(AppearanceKey.blocks) private var blocks = BlockPalette.patchbridge
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Appearance").font(.largeTitle.bold()).padding(.bottom, 8)
                Text("Theme").font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: themeColumns), spacing: 10) {
                    ForEach(ThemeID.allCases, id: \.self) { card($0) }
                }
                Text("Mode").font(.headline).padding(.top, 12)
                modePicker
                Text(modeNote).font(.footnote).foregroundStyle(theme.muted)
                contrastRow.padding(.top, 12)
                Text("Block colors").font(.headline).padding(.top, 12)
                if BlockPalette.available.count > 1 {
                    Picker("Block colors", selection: choose($blocks)) {
                        ForEach(BlockPalette.available, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }
                legend
                Text(theme.blocks == .qcMatch ? "QC Match colors are placeholders until they're sampled from a Quad Cortex. Scene colors always come from your QC."
                     : "Scene colors always come from your QC.")
                    .font(.footnote).foregroundStyle(theme.muted)
            }
        }.scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: themeID)
        .sensoryFeedback(.selection, trigger: mode)
    }

    private var themeColumns: Int {
        if dynamicTypeSize.isAccessibilitySize { return 1 }
        return dynamicTypeSize >= .xxLarge ? 2 : 3
    }
    /// Re-theming crossfades, or switches at once under Reduce Motion.
    private func choose<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        binding.animation(reduceMotion ? nil : .easeOut(duration: 0.25))
    }

    private func card(_ id: ThemeID) -> some View {
        let preview = PhoneTheme(id, daylight: theme.daylight, highContrast: theme.highContrast, blocks: theme.blocks)
        let active = id == themeID
        return Button { choose($themeID).wrappedValue = id } label: {
            VStack(alignment: .leading, spacing: 8) {
                miniature(preview)
                HStack(spacing: 4) {
                    Text(id.rawValue).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.signal) }
                }.padding(.horizontal, 4).frame(minHeight: 22)
            }.padding(6).frame(maxWidth: .infinity)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(active ? theme.signal : theme.line, lineWidth: active ? 2 : theme.hairline))
                .contentShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).accessibilityIdentifier("theme-\(id.rawValue)")
            .accessibilityLabel("\(id.rawValue) theme")
            .accessibilityValue(active ? "Selected" : "Not selected")
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// The overview in that theme and the current mode, drawn with the demo preset.
    private func miniature(_ preview: PhoneTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(DemoFixture.name).font(.system(size: 11, weight: .bold)).foregroundStyle(preview.ink).lineLimit(1)
            HStack(spacing: 3) {
                ForEach(DemoFixture.sceneColors.indices, id: \.self) { index in
                    Circle().fill(DemoFixture.sceneColors[index]).frame(width: 5, height: 5)
                        .overlay(Circle().stroke(preview.daylight ? preview.ink : .clear, lineWidth: 0.5))
                }
            }
            DemoGrid(theme: preview, cell: 8, codes: false).padding(3).background(preview.surface, in: RoundedRectangle(cornerRadius: 6))
            Capsule().fill(preview.signal).frame(height: 13)
                .overlay(Text("Save").font(.system(size: 8, weight: .bold)).foregroundStyle(preview.signalInk))
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(preview.ground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(preview.line, lineWidth: preview.hairline))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var modePicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // Segments can't fit accessibility text sizes, so each mode gets its own row.
            VStack(spacing: 0) {
                ForEach(AppearanceMode.allCases, id: \.self) { option in
                    Button { choose($mode).wrappedValue = option } label: {
                        HStack {
                            Text(option.rawValue)
                            Spacer()
                            if option == mode { Image(systemName: "checkmark").foregroundStyle(theme.signal) }
                        }.padding(.horizontal, 16).frame(minHeight: 56).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(option == mode ? .isSelected : [])
                    if option != AppearanceMode.allCases.last { Rectangle().fill(theme.line).frame(height: theme.hairline).padding(.leading, 16) }
                }
            }
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.line, lineWidth: theme.hairline))
        } else {
            Picker("Mode", selection: choose($mode)) {
                ForEach(AppearanceMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
        }
    }
    private var modeNote: String {
        switch mode {
        case .dark: "For dim studios and stages."
        case .light: "For bright rooms. \(themeID.rawValue) keeps its accent."
        case .auto: "Follows your \(deviceName)'s Light and Dark setting."
        }
    }

    /// Increase Contrast in Settings always wins, so the row reports it rather than offering a switch that can't turn off.
    @ViewBuilder private var contrastRow: some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            Text("High contrast")
            Text(systemContrast == .increased ? "On while Increase Contrast is on in Settings" : "Always on when Increase Contrast is on")
                .font(.footnote).foregroundStyle(theme.muted)
        }
        Group {
            if systemContrast == .increased {
                HStack { label; Spacer(); Text("On").foregroundStyle(theme.muted) }
                    .accessibilityElement(children: .combine)
            } else {
                Toggle(isOn: choose($highContrast)) { label }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 56)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.line, lineWidth: theme.hairline))
    }

    private var legend: some View {
        LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
            ForEach(["Dynamics", "Overdrive", "Amp", "Cab", "Modulation", "Delay", "Reverb", "Wah", "Capture", "Pitch", "Utility"], id: \.self) { name in
                let category = BlockCategory(name, palette: theme.blocks)
                HStack(spacing: 10) {
                    Text(category.code).font(.caption2.bold()).frame(width: 44, height: 28)
                        .foregroundStyle(category.darkInk ? Color(hex: 0x161611) : .white)
                        .background(category.color, in: RoundedRectangle(cornerRadius: 8))
                        .blockOutline(theme, cornerRadius: 8)
                        .accessibilityHidden(true)
                    Text(name).font(.subheadline)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.top, 4)
    }
}
