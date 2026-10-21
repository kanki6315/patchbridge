import SwiftUI

/// The pitch on screen. Apart from `TunerModel` so only the readouts redraw ten times a second,
/// never the screens that just need to know whether the tuner is on.
final class TunerReadout: ObservableObject {
    @Published var pitch: TunerPitch?
}

/// The tuner every layout shows: its mode, mute and errors.
final class TunerModel: ObservableObject {
    let readout = TunerReadout()
    /// The full tuner is showing. The QC shows its tuner then, so mute applies.
    @Published private(set) var open = false
    /// Pitch stays on screen after the full tuner closes. It never mutes.
    @Published private(set) var live = false
    @Published private(set) var muted: Bool?
    /// A mute change the QC hasn't confirmed yet.
    @Published private(set) var requestedMute: Bool?
    @Published private(set) var error: String?
    weak var phone: PhoneModel?
    private var timer: Timer?
    private var demoStarted: TimeInterval = 0
    private var demoMuted = false

    private var demo: Bool { phone?.usesLocalFixture == true }
    private var coordinator: EditorCoordinator? { phone?.coordinator }
    var available: Bool { demo || coordinator?.tunerAvailable == true }
    var canMute: Bool { demo || coordinator?.tunerMuteAvailable == true }
    var displayedMute: Bool { requestedMute ?? muted ?? false }
    var mode: EditorCoordinator.TunerMode { open ? .open : live ? .live : .off }

    func setOpen(_ open: Bool) { guard open != self.open else { return }; self.open = open; apply() }
    func setLive(_ live: Bool) { guard live != self.live else { return }; self.live = live; apply() }
    func setMuted(_ value: Bool) {
        guard open, canMute else { return }
        if demo { demoMuted = value; muted = value; return }
        requestedMute = value; error = nil
        coordinator?.setTunerMuted(value)
    }
    /// The connection ended or the demo changed: everything starts closed and off.
    func reset() {
        open = false; live = false; readout.pitch = nil; muted = nil; requestedMute = nil; error = nil; demoMuted = false
        timer?.invalidate(); timer = nil
    }

    private func apply() {
        if !demo { coordinator?.setTuner(mode) }
        else if mode != .off && timer == nil { demoStarted = ProcessInfo.processInfo.systemUptime; muted = demoMuted }
        if mode == .off {
            timer?.invalidate(); timer = nil; readout.pitch = nil; requestedMute = nil
        } else if timer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
        refresh()
    }
    private func refresh() {
        let next = demo ? demoPitch(ProcessInfo.processInfo.systemUptime - demoStarted) : coordinator?.tunerPitch()
        if next != readout.pitch { readout.pitch = next }
        guard !demo, let coordinator else { return }
        if muted != coordinator.tunerMuted { muted = coordinator.tunerMuted }
        if let requested = requestedMute, coordinator.tunerMuted == requested || coordinator.tunerError != nil { requestedMute = nil }
        if error != coordinator.tunerError { error = coordinator.tunerError }
    }

    /// Demo mode has no QC: strings are plucked off pitch, settle while they ring, then go quiet.
    private func demoPitch(_ t: TimeInterval) -> TunerPitch? {
        #if DEBUG
        if phone?.screenshotFixture == true {
            if ProcessInfo.processInfo.arguments.contains("--preview-story") {
                // A simulated A string settles from flat to in tune; still captures stay fixed.
                let cents = t < 2.8 ? -19 * pow(max(0, 1 - t / 2.8), 1.6) : 0
                return TunerPitch(hz: 110 * pow(2, cents / 1200))
            }
            return TunerPitch(hz: 110 * pow(2, 2.0 / 1200))
        }
        #endif
        let strings: [(Double, Double)] = [(82.41, 22), (110, -16), (146.83, 9), (196, -26), (246.94, 12), (329.63, -8)]
        let ring = 4.5, cycle = 6.0
        let index = Int(t / cycle) % strings.count, ringing = t.truncatingRemainder(dividingBy: cycle)
        guard ringing < ring else { return nil }
        let settle = 1 - exp(-ringing)
        let cents = strings[index].1 * (1 - settle) + 1.2 * sin(ringing * 3.5) * (1 - 0.7 * settle)
        return TunerPitch(hz: strings[index].0 * pow(2, cents / 1200))
    }
}

private let tunerEase = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.12)

/// The note with its octave, or a dash while the strings are quiet.
struct TunerNote: View {
    let pitch: TunerPitch?
    let theme: PhoneTheme
    let size: CGFloat
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(pitch?.note ?? "–").font(.system(size: size, weight: pitch == nil ? .light : .bold)).foregroundStyle(pitch == nil ? theme.muted : theme.ink)
            Text(pitch.map { String($0.octave) } ?? "").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(theme.muted)
        }.monospacedDigit().lineLimit(1).fixedSize()
    }
}

/// "+6¢", turning to the signal color in tune. Empty while quiet.
struct TunerCents: View {
    let pitch: TunerPitch?
    let theme: PhoneTheme
    let size: CGFloat
    static func text(_ pitch: TunerPitch?) -> String {
        guard let pitch else { return "" }
        let cents = Int(pitch.cents.rounded())
        return cents == 0 ? "0¢" : (cents > 0 ? "+" : "−") + "\(abs(cents))¢"
    }
    var body: some View {
        Text(Self.text(pitch)).font(.system(size: size, weight: .semibold)).monospacedDigit()
            .foregroundStyle(pitch?.inTune == true ? theme.signal : theme.muted)
    }
}

/// ±50 cents with the target zone in the middle. The marker fills with the signal color in tune.
struct TunerBar: View {
    let pitch: TunerPitch?
    let theme: PhoneTheme
    var height: CGFloat = 8
    var radius: CGFloat?
    var markerWidth: CGFloat = 4
    /// How far the marker reaches above and below a slim track.
    var overshoot: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, inTune = pitch?.inTune == true
            let shape = RoundedRectangle(cornerRadius: radius ?? height / 2)
            // A slim track lights along its length in tune; a tall one fills its centre zone.
            let slim = radius == nil
            ZStack(alignment: .leading) {
                shape.fill(slim && inTune ? theme.signal.opacity(0.4) : theme.ink.opacity(0.09)).frame(height: height)
                ForEach([-40, -30, -20, -10, 10, 20, 30, 40], id: \.self) { cents in
                    Rectangle().fill(theme.ink.opacity(0.2)).frame(width: 1, height: height * 0.45)
                        .offset(x: width * CGFloat(50 + cents) / 100)
                }
                RoundedRectangle(cornerRadius: radius ?? height / 2).fill(inTune && !slim ? theme.signal : theme.ink.opacity(inTune ? 0 : 0.1))
                    .frame(width: width * 0.08, height: height).offset(x: width * 0.46)
                // Always present, hidden while quiet, so a new string's first reading shows at once.
                let x = width * CGFloat(50 + min(50, max(-50, pitch?.cents ?? 0))) / 100
                Capsule().fill(inTune ? (radius == nil ? theme.signal : theme.signalInk) : theme.ink)
                    .frame(width: markerWidth, height: height + overshoot * 2 - (radius == nil ? 0 : height * 0.24))
                    .shadow(color: (inTune ? theme.signal : theme.ink).opacity(radius == nil ? 0.6 : 0), radius: 6)
                    .offset(x: x - markerWidth / 2)
                    .opacity(pitch == nil ? 0 : 1)
            }
            .frame(width: width, height: geometry.size.height)
            .animation(reduceMotion ? nil : tunerEase, value: pitch?.cents)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: inTune)
        }
        .frame(height: height + overshoot * 2)
        .accessibilityHidden(true)
    }
}

extension View {
    /// One light tap as the string comes into tune.
    func tunerHaptic(_ pitch: TunerPitch?) -> some View {
        sensoryFeedback(.impact(weight: .light), trigger: pitch?.inTune == true) { old, new in new && !old }
    }
    func tunerAccessibility(_ pitch: TunerPitch?) -> some View {
        accessibilityElement(children: .ignore).accessibilityLabel("Tuner")
            .accessibilityValue(pitch.map { "\($0.note)\($0.octave), " + ($0.inTune ? "in tune" : "\(abs(Int($0.cents.rounded()))) cents \($0.cents > 0 ? "sharp" : "flat")") } ?? "No signal")
    }
}

/// A soft light at the marker that widens and brightens as the string closes in, and spreads in tune.
struct TunerGlow: View {
    let pitch: TunerPitch?
    let theme: PhoneTheme
    /// The glow's size off pitch, at its closest, and in tune.
    let far: CGSize, near: CGSize, tuned: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let inTune = pitch?.inTune == true
        let closeness = pitch.map { inTune ? 1 : max(0.2, 1 - abs($0.cents) / 40) } ?? 0
        let size = inTune ? tuned : CGSize(width: far.width + (near.width - far.width) * closeness, height: far.height + (near.height - far.height) * closeness)
        let color = inTune ? theme.signal.opacity(theme.daylight ? 0.28 : 0.5) : theme.ink.opacity(theme.daylight ? 0.04 + 0.06 * closeness : 0.1 + 0.18 * closeness)
        EllipticalGradient(colors: [color, color.opacity(0)], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
            .frame(width: size.width, height: size.height)
            .opacity(pitch == nil ? 0 : 1)
            .blendMode(theme.daylight ? .normal : .screen)
            .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.22), value: size)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Opens the full tuner. Filled with the signal color while the live tuner is on.
struct TunerButton: View {
    @ObservedObject var tuner: TunerModel
    let theme: PhoneTheme
    var size: CGFloat = 44
    let action: () -> Void
    var body: some View {
        let on = tuner.live
        Button(action: action) {
            Image(systemName: "tuningfork").font(.system(size: size * 0.4, weight: .semibold)).frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? theme.signalInk : theme.ink)
        .background { if on { Circle().fill(theme.signal) } }
        .modifier(GlassIf(enabled: !on, theme: theme, radius: size / 2))
        .accessibilityLabel("Tuner").accessibilityValue(on ? "Live tuner on" : "").accessibilityIdentifier("tuner-button")
    }
}
private struct GlassIf: ViewModifier {
    let enabled: Bool
    let theme: PhoneTheme
    let radius: CGFloat
    func body(content: Content) -> some View { if enabled { content.phoneGlass(theme, radius: radius) } else { content } }
}

/// iPhone: a slim line under the status bar. A pitch-following highlight opens into
/// a steady full-width line in tune, while a soft glow rises around the camera area.
struct TunerLine: View {
    @ObservedObject var readout: TunerReadout
    let theme: PhoneTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let open: () -> Void
    static let height: CGFloat = 44
    /// The highlight sits just under the marker and hangs past the line's layout into the
    /// content below, so the screen starts right after the readout instead of after the light.
    private static let floor: CGFloat = 38, overhang: CGFloat = 10
    private let note: CGFloat = 34, cents: CGFloat = 44, gap: CGFloat = 12, side: CGFloat = 20
    var body: some View {
        Button(action: open) {
            HStack(spacing: gap) {
                TunerNote(pitch: readout.pitch, theme: theme, size: 22).frame(width: note, alignment: .leading)
                TunerBar(pitch: readout.pitch, theme: theme, height: 6, markerWidth: 4, overshoot: 8)
                TunerCents(pitch: readout.pitch, theme: theme, size: 15).frame(width: cents, alignment: .trailing)
            }
            .padding(.horizontal, side).frame(height: Self.height).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background { GeometryReader { geometry in light(width: geometry.size.width) } }
        .tunerAccessibility(readout.pitch).accessibilityAddTraits(.isButton).accessibilityHint("Opens the full tuner").accessibilityIdentifier("tuner-line")
        .tunerHaptic(readout.pitch)
        .padding(.bottom, -Self.overhang)
    }
    private func light(width: CGFloat) -> some View {
        let pitch = readout.pitch
        let inTune = pitch?.inTune == true
        let start = side + note + gap, span = max(1, width - start - gap - cents - side)
        let marker = start + span * CGFloat(50 + min(50, max(-50, pitch?.cents ?? 0))) / 100
        let available = max(1, width - 2 * side)
        let closeness = max(0, 1 - abs(pitch?.cents ?? 50) / 50)
        // Reduce Motion keeps the light stationary; color and opacity still confirm tuning.
        let spread = reduceMotion || inTune ? available : min(available, 32 + 48 * closeness)
        let center = reduceMotion || inTune ? width / 2 : marker
        let color = inTune ? theme.signal : theme.ink
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.clear, color.opacity(theme.daylight ? 0.06 : 0.10)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: spread, height: 16)
                .mask(LinearGradient(colors: [.clear, .white, .white, .clear], startPoint: .leading, endPoint: .trailing))
                .position(x: center, y: Self.floor - 7)
            Capsule()
                .fill(LinearGradient(colors: [color.opacity(0), color, color, color.opacity(0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: spread, height: 2)
                .position(x: center, y: Self.floor)
        }
        .frame(width: width, height: Self.height)
        .clipped()
        .opacity(pitch == nil ? 0 : (inTune ? 1 : 0.45))
        .animation(reduceMotion ? nil : tunerEase, value: pitch?.cents)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: inTune)
        .animation(.easeOut(duration: 0.15), value: pitch == nil)
        .background {
            // Ambient light reaches behind the status bar without assuming a camera shape.
            if reduceMotion {
                EllipticalGradient(colors: [color.opacity(theme.daylight ? 0.18 : 0.35), .clear],
                                   center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                    .frame(width: width * 1.3, height: 280)
                    .position(x: width / 2, y: Self.height / 2 - 30)
                    .opacity(pitch == nil ? 0 : (inTune ? 1 : 0.3))
                    .animation(.easeOut(duration: 0.15), value: inTune)
                    .animation(.easeOut(duration: 0.15), value: pitch == nil)
            } else {
                TunerGlow(pitch: pitch, theme: theme,
                          far: CGSize(width: 160, height: 130),
                          near: CGSize(width: 340, height: 240),
                          tuned: CGSize(width: max(560, width * 1.3), height: 280))
                    .position(x: center, y: Self.height / 2 - (inTune ? 30 : 10))
                    .animation(tunerEase, value: pitch?.cents)
                    .animation(.easeOut(duration: 0.24), value: inTune)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The full tuner's readout and controls, for the iPhone sheet and the iPad and Duo popovers.
struct TunerPanel: View {
    @ObservedObject var tuner: TunerModel
    @ObservedObject var readout: TunerReadout
    let theme: PhoneTheme
    var compact = false
    init(tuner: TunerModel, theme: PhoneTheme, compact: Bool = false) {
        self.tuner = tuner; self.readout = tuner.readout; self.theme = theme; self.compact = compact
    }
    var body: some View {
        VStack(spacing: compact ? 12 : 16) {
            Label("Output muted", systemImage: "speaker.slash").font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).frame(height: 30).background(theme.raised, in: Capsule())
                .opacity(tuner.displayedMute ? 1 : 0).accessibilityHidden(!tuner.displayedMute)
            VStack(spacing: compact ? 8 : 12) {
                TunerNote(pitch: readout.pitch, theme: theme, size: compact ? 96 : 132)
                TunerCents(pitch: readout.pitch, theme: theme, size: compact ? 28 : 34).frame(minHeight: compact ? 34 : 41)
                HStack(spacing: 8) {
                    Text("♭").font(.title2).foregroundStyle(theme.muted)
                    TunerBar(pitch: readout.pitch, theme: theme, height: compact ? 56 : 72, radius: 12, markerWidth: 6, overshoot: 0)
                    Text("♯").font(.title2).foregroundStyle(theme.muted)
                }
                HStack { Text("−50"); Spacer(); Text("0"); Spacer(); Text("+50") }
                    .font(.footnote.monospacedDigit()).foregroundStyle(theme.muted).padding(.horizontal, 26)
                Text(readout.pitch.map { String(format: "%.2f Hz", $0.hz) } ?? "No signal").font(.subheadline.monospacedDigit()).foregroundStyle(theme.muted)
            }
            .tunerAccessibility(readout.pitch).tunerHaptic(readout.pitch)
            Spacer(minLength: compact ? 4 : 12)
            VStack(spacing: 0) {
                if tuner.canMute {
                    Toggle(isOn: Binding(get: { tuner.displayedMute }, set: { tuner.setMuted($0) })) {
                        Label(tuner.requestedMute == nil ? "Mute output" : "Mute output · sending…", systemImage: "speaker.slash")
                    }.padding(.horizontal, 16).frame(minHeight: 56)
                    Rectangle().fill(theme.line).frame(height: 0.5).padding(.leading, 16)
                }
                Toggle("Live tuner", isOn: Binding(get: { tuner.live }, set: { tuner.setLive($0) }))
                    .padding(.horizontal, 16).frame(minHeight: 56)
            }
            .background(theme.raised, in: RoundedRectangle(cornerRadius: 18))
            if let error = tuner.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(theme.caution).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// iPhone, and the Duo's folded screens: the full tuner as a sheet.
struct TunerSheet: View {
    @ObservedObject var tuner: TunerModel
    let theme: PhoneTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Tuner").font(.title2.bold())
                Spacer()
                Button("Done") { tuner.setOpen(false) }.font(.headline).padding(.horizontal, 16).frame(minHeight: 44).background(theme.raised, in: Capsule())
            }
            TunerPanel(tuner: tuner, theme: theme)
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.surface.ignoresSafeArea()).foregroundStyle(theme.ink).tint(theme.signal)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .preferredColorScheme(theme.daylight ? .light : .dark)
    }
}

/// iPad and the Duo's inner screen: the full tuner as a popover from the tuner button.
struct TunerPopover: View {
    @ObservedObject var tuner: TunerModel
    let theme: PhoneTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tuner").font(.title2.bold())
            TunerPanel(tuner: tuner, theme: theme, compact: true)
        }
        .padding(18).frame(width: 380)
        .foregroundStyle(theme.ink).tint(theme.signal)
        .presentationCompactAdaptation(.popover)
        // Like the other popovers: nearly opaque, so the readout never reads over the grid.
        .presentationBackground(theme.surface.opacity(0.95))
        .preferredColorScheme(theme.daylight ? .light : .dark)
    }
}

/// iPad: the live tuner in the top bar's free space. Tapping it opens the full tuner.
struct TunerBand: View {
    @ObservedObject var readout: TunerReadout
    let theme: PhoneTheme
    /// Portrait has no free space in the top bar, so the band takes a full-width row there.
    var wide = false
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                TunerNote(pitch: readout.pitch, theme: theme, size: 26).frame(minWidth: 40, alignment: .leading)
                TunerBar(pitch: readout.pitch, theme: theme, height: 8, markerWidth: 4, overshoot: 9)
                TunerCents(pitch: readout.pitch, theme: theme, size: 17).frame(width: 46, alignment: .trailing)
            }
            .padding(.horizontal, 14).frame(height: 52)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.line))
        }
        .buttonStyle(.plain).frame(minWidth: 170, maxWidth: wide ? .infinity : 360).layoutPriority(-1)
        .tunerAccessibility(readout.pitch).accessibilityAddTraits(.isButton).accessibilityHint("Opens the full tuner")
        .tunerHaptic(readout.pitch)
    }
}

/// The Duo's inner screen: the tuner is the crease. Its bar runs along the fold and its light
/// spills into both halves, flat or half-folded. Nothing here takes a tap, so the fold stays clear.
struct TunerCrease: View {
    @ObservedObject var readout: TunerReadout
    let theme: PhoneTheme
    static let side: CGFloat = 26, note: CGFloat = 46, cents: CGFloat = 56, gap: CGFloat = 16
    var body: some View {
        HStack(spacing: Self.gap) {
            TunerNote(pitch: readout.pitch, theme: theme, size: 26).frame(width: Self.note, alignment: .leading)
            TunerBar(pitch: readout.pitch, theme: theme, height: 6, markerWidth: 5, overshoot: 11)
            TunerCents(pitch: readout.pitch, theme: theme, size: 18).frame(width: Self.cents, alignment: .trailing)
        }
        .padding(.horizontal, Self.side)
        .allowsHitTesting(false)
        .tunerAccessibility(readout.pitch).tunerHaptic(readout.pitch)
    }
}

/// The Duo's outer screen in portrait, where the status bar runs down the trailing edge: the tuner
/// lives in that column. The scale stays straight, sharp up toward the camera, so the cents read
/// honestly; only the light wraps, spreading from the camera along the top edge and down the status
/// bar's edge as the string closes in, and running the whole way around in tune. Nothing here takes a tap.
struct TunerColumn: View {
    @ObservedObject var readout: TunerReadout
    let theme: PhoneTheme
    /// The whole window, the column's width at its trailing edge, and where the system's items end.
    let window: CGSize
    let column: CGFloat
    let top: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let readoutHeight: CGFloat = 58, end: CGFloat = 26, track: CGFloat = 220
    var body: some View {
        ZStack(alignment: .topLeading) {
            light
            VStack(spacing: 0) {
                VStack(spacing: 2) {
                    TunerNote(pitch: readout.pitch, theme: theme, size: 26)
                    TunerCents(pitch: readout.pitch, theme: theme, size: 15).frame(height: 18)
                }.frame(height: Self.readoutHeight)
                Text("♯").frame(height: Self.end)
                TunerBar(pitch: readout.pitch, theme: theme, height: 6, markerWidth: 4, overshoot: 9)
                    .frame(width: Self.track).rotationEffect(.degrees(-90)).frame(width: 24, height: Self.track)
                Text("♭").frame(height: Self.end)
            }
            .font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.muted)
            .frame(width: column)
            .tunerAccessibility(readout.pitch).tunerHaptic(readout.pitch)
            .offset(x: window.width - column, y: top)
        }
        .frame(width: window.width, height: window.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
    private var light: some View {
        let pitch = readout.pitch
        let inTune = pitch?.inTune == true
        let x = window.width - column / 2
        let trackTop = top + Self.readoutHeight + Self.end
        let marker = trackTop + Self.track * CGFloat(50 - min(50, max(-50, pitch?.cents ?? 0))) / 100
        let closeness = max(0, 1 - abs(pitch?.cents ?? 50) / 50)
        let color = inTune ? theme.signal : theme.ink
        // Reduce Motion keeps the light at the camera; color and opacity still confirm tuning.
        let corner = reduceMotion || inTune
        // The edge light spreads from the camera along both arms; in tune it runs their whole length.
        let full = max(window.width, window.height) * 1.5
        let reach = inTune ? full : (reduceMotion ? 220 : 90 + 300 * closeness)
        let edge = Self.edge(window)
        return ZStack(alignment: .topLeading) {
            TunerGlow(pitch: pitch, theme: theme,
                      far: CGSize(width: 110, height: 150), near: CGSize(width: 200, height: 300),
                      tuned: CGSize(width: 460, height: 380))
                .position(x: x, y: corner ? 24 : marker)
                .animation(reduceMotion ? nil : tunerEase, value: pitch?.cents)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: inTune)
            ZStack {
                edge.stroke(color.opacity(theme.daylight ? 0.22 : 0.3), style: StrokeStyle(lineWidth: 16, lineCap: .round)).blur(radius: 8)
                edge.stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            .frame(width: window.width, height: window.height)
            .mask(alignment: .topLeading) {
                EllipticalGradient(colors: [.white, .white, .clear], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                    .frame(width: reach * 2, height: reach * 2)
                    .position(x: x, y: 24)
            }
            .opacity(pitch == nil ? 0 : (inTune ? 1 : 0.4 + 0.35 * closeness))
            .animation(reduceMotion ? nil : tunerEase, value: pitch?.cents)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.36), value: inTune)
            .animation(.easeOut(duration: 0.15), value: pitch == nil)
        }
        .frame(width: window.width, height: window.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }
    /// The display's corner radius isn't public; this follows the outer screen's rounding closely
    /// enough that the line stays on the glass around the corner.
    static let screenCorner: CGFloat = 52
    /// Along the top edge, around the camera's corner and down the status bar's edge.
    static func edge(_ window: CGSize) -> Path {
        let r = screenCorner, inset: CGFloat = 1.5
        var path = Path()
        path.move(to: CGPoint(x: r, y: inset))
        path.addLine(to: CGPoint(x: window.width - r, y: inset))
        path.addArc(center: CGPoint(x: window.width - r, y: r), radius: r - inset, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: window.width - inset, y: window.height - r))
        return path
    }
}

/// The crease's light, placed at the marker on a screen `width` wide with the fold at `foldY`.
struct TunerCreaseLight: View {
    @ObservedObject var readout: TunerReadout
    let theme: PhoneTheme
    let width: CGFloat
    let foldY: CGFloat
    var body: some View {
        let start = TunerCrease.side + TunerCrease.note + TunerCrease.gap
        let span = max(1, width - 2 * TunerCrease.side - TunerCrease.note - TunerCrease.cents - 2 * TunerCrease.gap)
        let inTune = readout.pitch?.inTune == true
        let x = inTune ? width / 2 : start + span * CGFloat(50 + min(50, max(-50, readout.pitch?.cents ?? 0))) / 100
        TunerGlow(pitch: readout.pitch, theme: theme, far: CGSize(width: 200, height: 150), near: CGSize(width: 420, height: 450), tuned: CGSize(width: width * 1.3, height: 520))
            .position(x: x, y: foldY)
    }
}
