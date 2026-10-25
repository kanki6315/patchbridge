import Foundation

/// A theme is a ground tint and one accent. Each has a dark and a light version; the player
/// picks the theme and the mode separately. Compiled into the app and the widget extension.
enum ThemeID: String, CaseIterable, Codable {
    case stage = "Stage", ember = "Ember", midnight = "Midnight", mint = "Mint", lavender = "Lavender", mono = "Mono"

    /// 0xRRGGBB values for one theme in one mode.
    struct Tokens {
        let ground, surface, raised, ink, muted, line, signal, signalInk: UInt32
    }

    func tokens(daylight: Bool, highContrast: Bool = false) -> Tokens {
        let base = daylight ? light : dark
        guard highContrast else { return base }
        // High contrast: pure ground, muted text close to ink, strong gray hairlines (filled blocks
        // get an ink outline, so they stay distinct from empty slots), and light accents deepened
        // to at least 7:1 on white. Dark accents already clear 7:1 on black.
        return daylight
            ? Tokens(ground: 0xffffff, surface: 0xffffff, raised: 0xefefef, ink: 0x000000, muted: 0x333333, line: 0x6b6b66,
                     signal: contrastSignal ?? base.signal, signalInk: base.signalInk)
            : Tokens(ground: 0x000000, surface: 0x000000, raised: 0x1a1a1a, ink: 0xffffff, muted: 0xd6d6d0, line: 0x9a9a94,
                     signal: base.signal, signalInk: base.signalInk)
    }

    private var dark: Tokens {
        switch self {
        case .stage: Tokens(ground: 0x0d0e0a, surface: 0x161612, raised: 0x24241f, ink: 0xf2f2ee, muted: 0xb1b2ab, line: 0x2e2e29, signal: 0xd1e14a, signalInk: 0x161802)
        case .ember: Tokens(ground: 0x070505, surface: 0x120c0b, raised: 0x1a1210, ink: 0xe8c9bf, muted: 0xa8877d, line: 0x2a201d, signal: 0xff6a3d, signalInk: 0x1a0602)
        case .midnight: Tokens(ground: 0x080a12, surface: 0x10131d, raised: 0x1c2030, ink: 0xeef0f7, muted: 0xaab0c4, line: 0x272b3b, signal: 0x9fb4ff, signalInk: 0x0a0f24)
        case .mint: Tokens(ground: 0x06100c, surface: 0x0d1713, raised: 0x17221d, ink: 0xeef4f0, muted: 0xa9b8b0, line: 0x223029, signal: 0x6ef2c0, signalInk: 0x03190f)
        case .lavender: Tokens(ground: 0x0d0a12, surface: 0x15111b, raised: 0x221d2c, ink: 0xf2eff7, muted: 0xb6aec4, line: 0x2d2738, signal: 0xc9a6ff, signalInk: 0x1a0c33)
        case .mono: Tokens(ground: 0x0b0b0b, surface: 0x151515, raised: 0x222222, ink: 0xf2f2f2, muted: 0xb3b3b3, line: 0x2e2e2e, signal: 0xf2f2f2, signalInk: 0x0b0b0b)
        }
    }

    private var light: Tokens {
        switch self {
        case .stage: Tokens(ground: 0xf7f7f5, surface: 0xffffff, raised: 0xe9e9e5, ink: 0x161611, muted: 0x555650, line: 0xd1d1cd, signal: 0x5c6400, signalInk: 0xffffff)
        case .ember: Tokens(ground: 0xf8f6f5, surface: 0xffffff, raised: 0xece6e3, ink: 0x1a1210, muted: 0x5e504b, line: 0xd6cfcc, signal: 0xa8360f, signalInk: 0xffffff)
        case .midnight: Tokens(ground: 0xf5f6f9, surface: 0xffffff, raised: 0xe5e7ee, ink: 0x10131f, muted: 0x4f5468, line: 0xcfd2dc, signal: 0x3a4fb8, signalInk: 0xffffff)
        case .mint: Tokens(ground: 0xf4f8f6, surface: 0xffffff, raised: 0xe3ebe7, ink: 0x0e1a14, muted: 0x4a5a52, line: 0xcbd6d0, signal: 0x00704e, signalInk: 0xffffff)
        case .lavender: Tokens(ground: 0xf7f5f9, surface: 0xffffff, raised: 0xe8e4ee, ink: 0x17121f, muted: 0x574f66, line: 0xd4cfdc, signal: 0x6a3fb8, signalInk: 0xffffff)
        case .mono: Tokens(ground: 0xf6f6f6, surface: 0xffffff, raised: 0xe6e6e6, ink: 0x111111, muted: 0x555555, line: 0xd0d0d0, signal: 0x111111, signalInk: 0xffffff)
        }
    }

    /// Light accents below 7:1 on white, deepened for high contrast.
    private var contrastSignal: UInt32? {
        switch self {
        case .stage: 0x4a5000
        case .ember: 0x8f2e0c
        case .mint: 0x005c40
        default: nil
        }
    }
}
