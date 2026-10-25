import SwiftUI

/// The scenes as buttons. Each cell always draws the scene the QC confirmed as active; a tap
/// only marks the tapped cell (pending, then not applied) until the QC answers. Cells stay
/// display-only until the bridge advertises `select_scene`.
struct SceneButtons: View {
    enum Style {
        /// iPhone: eight 44 pt cells with a dot and letter.
        case strip
        /// iPad: the QC's name under the dot and letter.
        case named
        /// iPhone Duo deck: footswitch-sized pads, two rows of four.
        case pads
    }
    @ObservedObject var model: PhoneModel
    let snapshot: PresetSnapshot
    let theme: PhoneTheme
    let style: Style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if style == .pads {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow { ForEach(0..<4, id: \.self) { cell($0) } }
                    GridRow { ForEach(4..<8, id: \.self) { cell($0) } }
                }
            } else {
                HStack(spacing: style == .strip ? 5 : 6) { ForEach(0..<8, id: \.self) { cell($0) } }
            }
        }
        // Ring and glow cross-fade over 240 ms, ease-out-quart.
        .animation(reduceMotion ? nil : .timingCurve(0.25, 1, 0.5, 1, duration: 0.24), value: snapshot.scene)
        .animation(reduceMotion ? nil : .timingCurve(0.25, 1, 0.5, 1, duration: 0.24), value: model.sceneSwitch)
    }

    private func cell(_ index: Int) -> some View {
        let letter = PresetSnapshot.sceneLetters[index]
        let active = snapshot.scene == letter
        let mark = model.sceneMark(letter)
        let live = model.canSwitchScenes
        let shape = RoundedRectangle(cornerRadius: style == .pads ? 26 : 14)
        let color = model.sceneColor(theme, index)
        return Button { model.selectScene(letter) } label: {
            content(index, letter: letter, active: active, live: live)
                .frame(maxWidth: .infinity)
                .frame(minHeight: style == .pads ? 0 : 44, maxHeight: style == .pads ? .infinity : nil)
                .frame(height: style == .named ? 52 : nil)
                .background(active ? theme.raised : .clear, in: shape)
                .background(active && style == .pads ? color.opacity(theme.daylight ? 0.1 : 0.16) : .clear, in: shape)
                .overlay {
                    switch (active, mark) {
                    case (_, .pending): shape.stroke(theme.signal, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    case (_, .notApplied): shape.stroke(theme.caution, lineWidth: 1.5)
                    case (true, _): shape.stroke(color, lineWidth: style == .pads ? 2 : 1.5)
                    default: shape.stroke(live ? theme.line : .clear, lineWidth: 1)
                    }
                }
                .shadow(color: active && style == .pads && !theme.daylight ? color.opacity(0.35) : .clear, radius: 14)
                .sceneArrival(scene: snapshot.scene, active: active, color: color, shape: shape,
                              spread: style == .pads ? 16 : 10, daylight: theme.daylight)
                .anchorPreference(key: SceneOriginKey.self, value: .bounds) { active && style == .pads ? $0 : nil }
                .overlay(alignment: .topTrailing) {
                    if mark == .notApplied {
                        Text("!").font(.caption.weight(.heavy)).foregroundStyle(theme.signalInk)
                            .frame(width: 20, height: 20).background(theme.caution, in: Circle())
                            .offset(x: 6, y: -8).accessibilityHidden(true)
                    }
                }
                .contentShape(shape)
                // On the label itself: a Button otherwise reads its children ("B, CRONCH").
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.sceneAccessibilityLabel(letter))
        }
        .buttonStyle(.plain)
        .disabled(!live)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityHint(live && !active ? "Switches the QC to this scene" : "")
    }

    @ViewBuilder private func content(_ index: Int, letter: String, active: Bool, live: Bool) -> some View {
        let name = model.sceneName(index)
        // Read-only: the active scene keeps its colour; the rest dim.
        let dot = SceneDot(color: model.sceneColor(theme, index), size: dotSize(active), glow: active && !theme.daylight, theme: theme)
            .opacity(live || active || !model.scenesReadOnly ? 1 : 0.4)
        switch style {
        case .strip:
            VStack(spacing: 3) {
                dot
                Text(letter).font(.subheadline.weight(active ? .bold : .medium))
            }
        case .named:
            VStack(spacing: 3) {
                HStack(spacing: 6) { dot; Text(letter).font(.headline.weight(active ? .bold : .semibold)) }
                if !name.isEmpty {
                    Text(name.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(active ? theme.ink : theme.muted)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }.padding(.horizontal, 4)
        case .pads:
            VStack(alignment: .leading, spacing: 0) {
                dot
                Spacer(minLength: 8)
                Text(letter).font(.system(size: 52, weight: .bold)).foregroundStyle(active ? theme.ink : theme.muted)
                Text(name.isEmpty ? " " : name.uppercased()).font(.headline).foregroundStyle(active ? theme.ink : theme.muted)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
    private func dotSize(_ active: Bool) -> CGFloat {
        switch style {
        case .strip: return active ? 13 : 10
        case .named: return active ? 12 : 10
        case .pads: return active ? 22 : 18
        }
    }
}

/// When the QC lands on a new scene, from the phone or the unit's footswitches, the newly active
/// cell pops, flashes its scene colour and sends a ring outward. Other cells are untouched.
private struct SceneArrival: ViewModifier {
    let scene: String
    let active: Bool
    let color: Color
    let shape: RoundedRectangle
    /// How far the ring travels past the cell's edge.
    let spread: CGFloat
    let daylight: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrivals = 0

    private struct Arrival {
        var scale: CGFloat = 1
        var fill: Double = 0
        var spread: CGFloat = 0
        var ring: Double = 0
    }

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: Arrival(), trigger: arrivals) { view, arrival in
                view
                    .overlay {
                        if active {
                            // Over the cell's opaque fill; the blend tints the ground and leaves text as it is.
                            shape.fill(color.opacity(arrival.fill)).blendMode(daylight ? .multiply : .screen)
                            shape.stroke(color, lineWidth: 2).padding(-arrival.spread).opacity(arrival.ring)
                        }
                    }
                    .scaleEffect(active ? arrival.scale : 1)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.12, duration: 0.14, spring: .snappy)
                    SpringKeyframe(1, duration: 0.4, spring: .bouncy)
                }
                KeyframeTrack(\.fill) {
                    LinearKeyframe(daylight ? 0.3 : 0.4, duration: 0.06)
                    CubicKeyframe(0, duration: 0.6)
                }
                KeyframeTrack(\.spread) {
                    LinearKeyframe(0, duration: 0.06)
                    CubicKeyframe(spread, duration: 0.6)
                }
                KeyframeTrack(\.ring) {
                    LinearKeyframe(0.9, duration: 0.06)
                    CubicKeyframe(0, duration: 0.6)
                }
            }
            .onChange(of: scene) { old, new in if old != new && !reduceMotion { arrivals += 1 } }
    }
}

extension View {
    func sceneArrival(scene: String, active: Bool, color: Color, shape: RoundedRectangle, spread: CGFloat = 10, daylight: Bool) -> some View {
        modifier(SceneArrival(scene: scene, active: active, color: color, shape: shape, spread: spread, daylight: daylight))
    }
}

/// Where the active scene pad sits, so the deck's scene change can flood out from it.
struct SceneOriginKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// The Duo deck's scene change, over the whole lower half: a tinted shade floods out from the
/// active pad and sets the pads back, so the scene's letter and name read clearly in the middle.
/// It never takes touches, so the next tap lands while it plays.
private struct SceneWash: ViewModifier {
    let scene: String
    let name: String
    let color: Color
    let ink: Color
    let ground: Color
    let daylight: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrivals = 0

    private struct Wash {
        var reach: CGFloat = 0
        var fill: Double = 0
        var dim: Double = 0
        var front: Double = 0
        var label: Double = 0
        var scale: CGFloat = 0.85
    }

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(SceneOriginKey.self) { anchor in
            GeometryReader { proxy in
                let bounds = CGRect(origin: .zero, size: proxy.size)
                let pad = anchor.map { proxy[$0] } ?? CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
                let origin = CGPoint(x: pad.midX, y: pad.midY)
                // Far enough to reach the deck's farthest corner.
                let far = [CGPoint(x: 0, y: 0), CGPoint(x: bounds.maxX, y: 0), CGPoint(x: 0, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
                    .map { hypot($0.x - origin.x, $0.y - origin.y) }.max() ?? 0
                let start = max(pad.width, pad.height) / 2
                Color.clear.keyframeAnimator(initialValue: Wash(), trigger: arrivals) { view, wash in
                    let radius = start + (far - start) * wash.reach
                    view.overlay {
                        ZStack {
                            Circle().fill(ground.opacity(wash.dim)).overlay(Circle().fill(color.opacity(wash.fill)))
                                .frame(width: radius * 2, height: radius * 2).position(origin)
                            Circle().stroke(color, lineWidth: 6).blur(radius: 6).opacity(wash.front)
                                .frame(width: radius * 2, height: radius * 2).position(origin)
                            VStack(spacing: -10) {
                                Text(scene).font(.system(size: 140, weight: .heavy, design: .rounded))
                                if !name.isEmpty { Text(name.uppercased()).font(.system(size: 34, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5) }
                            }
                            .foregroundStyle(ink)
                            // A halo of the ground keeps the label legible over the pads beneath it.
                            .shadow(color: ground.opacity(0.9), radius: 18)
                            .shadow(color: ground.opacity(0.6), radius: 6)
                            .padding(.horizontal, 24)
                            .scaleEffect(wash.scale).opacity(wash.label)
                            .position(x: bounds.midX, y: bounds.midY)
                        }
                    }
                } keyframes: { _ in
                    KeyframeTrack(\.reach) {
                        CubicKeyframe(1, duration: 0.55)
                    }
                    KeyframeTrack(\.fill) {
                        LinearKeyframe(daylight ? 0.12 : 0.18, duration: 0.05)
                        LinearKeyframe(daylight ? 0.12 : 0.18, duration: 0.6)
                        CubicKeyframe(0, duration: 0.45)
                    }
                    KeyframeTrack(\.dim) {
                        LinearKeyframe(daylight ? 0.8 : 0.85, duration: 0.05)
                        LinearKeyframe(daylight ? 0.8 : 0.85, duration: 0.6)
                        CubicKeyframe(0, duration: 0.45)
                    }
                    KeyframeTrack(\.front) {
                        LinearKeyframe(0.7, duration: 0.05)
                        CubicKeyframe(0, duration: 0.5)
                    }
                    // The label waits for the flood to pass the middle.
                    KeyframeTrack(\.label) {
                        LinearKeyframe(0, duration: 0.12)
                        LinearKeyframe(1, duration: 0.12)
                        LinearKeyframe(1, duration: 0.6)
                        CubicKeyframe(0, duration: 0.35)
                    }
                    KeyframeTrack(\.scale) {
                        LinearKeyframe(0.85, duration: 0.12)
                        SpringKeyframe(1, duration: 0.4, spring: .snappy)
                    }
                }
                .clipped()
            }
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onChange(of: scene) { old, new in if old != new && !reduceMotion { arrivals += 1 } }
    }
}

extension View {
    func sceneWash(scene: String, name: String, color: Color, ink: Color, ground: Color, daylight: Bool) -> some View {
        modifier(SceneWash(scene: scene, name: name, color: color, ink: ink, ground: ground, daylight: daylight))
    }
}

/// A scene's colour from the QC. In Daylight every dot gets a dark edge, because several QC
/// colours nearly vanish on the light ground.
struct SceneDot: View {
    let color: Color
    let size: CGFloat
    var glow = false
    let theme: PhoneTheme
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay(Circle().stroke(theme.daylight ? theme.ink : .clear, lineWidth: 1.5))
            .shadow(color: glow ? color.opacity(0.7) : .clear, radius: size * 0.45)
    }
}

/// One line saying where the last tap stands: switching, on the QC, not applied or unknown.
/// Read-only connections say so with a lock instead.
struct SceneStatus: View {
    @ObservedObject var model: PhoneModel
    let theme: PhoneTheme
    /// Names the scene's QC name too ("Switching to B · CRONCH"), where there's room.
    var named = false
    var body: some View {
        Group {
            switch model.sceneSwitch {
            case .pending(let scene)?:
                Label("Switching to \(title(scene))", systemImage: "circle.dotted").foregroundStyle(theme.signal)
            case .confirmed?:
                Label("On the QC", systemImage: "checkmark").foregroundStyle(theme.muted)
            case .notApplied?:
                Label("Not applied", systemImage: "exclamationmark.triangle").foregroundStyle(theme.caution)
            case .unknown?:
                Label("Outcome unknown", systemImage: "questionmark.circle").foregroundStyle(theme.caution)
            case nil:
                if model.scenesReadOnly { Label("Read-only", systemImage: "lock").foregroundStyle(theme.muted) }
            }
        }
        .font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }
    private func title(_ scene: String) -> String {
        guard named, let index = PresetSnapshot.sceneLetters.firstIndex(of: scene) else { return scene }
        let name = model.sceneName(index)
        return name.isEmpty ? scene : "\(scene) · \(name.uppercased())"
    }
}

/// The last edit, save or QC change as a small pill floating over the content, so a message
/// coming or going never moves the layout. Confirmations fade after a few seconds; failures stay
/// until the next message. Scene switches are left to `SceneStatus`. With an `idle` hint, the
/// hint holds the line and the pill takes its place.
struct NoticeToast: View {
    @ObservedObject var model: PhoneModel
    let theme: PhoneTheme
    var idle: String? = nil
    /// False where the view below already says it's sending, like the block editor.
    var sends = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var faded: String?
    private var message: (text: String, icon: String, failure: Bool, ongoing: Bool)? {
        if let text = model.error ?? model.notice ?? model.coordinator.outcome {
            let failure = model.error != nil || text.hasPrefix("Not ") || text.hasPrefix("Couldn")
            return (text, failure ? "exclamationmark.triangle" : "checkmark", failure, false)
        }
        if sends, let pending = model.editor.pending, pending.operation != "select_scene" {
            return (pending.operation == "save" ? "Saving…" : "Sending…", "arrow.triangle.2.circlepath", false, true)
        }
        return nil
    }
    var body: some View {
        let shown = message.flatMap { $0.text == faded ? nil : $0 }
        Group {
            if let idle { Text(idle).font(.footnote).foregroundStyle(theme.muted).lineLimit(1).opacity(shown == nil ? 1 : 0) }
            else { Color.clear.frame(height: 0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: idle == nil ? .top : .leading) {
            if let shown {
                Label(shown.text, systemImage: shown.icon).font(.footnote.weight(.semibold)).lineLimit(2)
                    .foregroundStyle(shown.failure ? theme.caution : theme.ink)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    // Solid, so the blocks behind it never tint the text.
                    .background(theme.raised, in: Capsule()).overlay(Capsule().stroke(theme.line))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: shown?.text)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .task(id: message?.text) {
            if faded != message?.text { faded = nil }
            guard let message, !message.failure, !message.ongoing else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { faded = message.text }
        }
    }
}

extension PhoneModel {
    enum SceneMark { case none, pending, notApplied }
    /// How the strip marks one scene's cell beyond the active ring.
    func sceneMark(_ letter: String) -> SceneMark {
        switch sceneSwitch {
        case .pending(letter)?: return .pending
        case .notApplied(letter)?: return .notApplied
        default: return .none
        }
    }
    /// "Scene F · RHYTHM", or "Scene C" when the QC has no name for it.
    func sceneTitle(_ letter: String) -> String {
        guard let index = PresetSnapshot.sceneLetters.firstIndex(of: letter) else { return "Scene \(letter)" }
        let name = sceneName(index)
        return "Scene \(letter)" + (name.isEmpty ? "" : " · \(name.uppercased())")
    }
    func sceneAccessibilityLabel(_ letter: String) -> String {
        let current = snapshot?.scene ?? ""
        switch sceneMark(letter) {
        case .notApplied: return "\(sceneTitle(letter)) not applied. The QC stayed on \(sceneTitle(current))."
        case .pending: return "\(sceneTitle(letter)), switching"
        case .none: return sceneTitle(letter) + (letter == current ? ", active" : "")
        }
    }
    /// The iPad's top-bar toast: what is happening, and what the QC is doing about it.
    var sceneToast: (title: String, detail: String, failure: Bool)? {
        let current = snapshot?.scene ?? ""
        switch sceneSwitch {
        case .pending(let scene)?: return ("Switching to \(sceneTitle(scene))", "Waiting for the QC", false)
        case .confirmed(let scene)?: return (sceneTitle(scene), "On the QC", false)
        case .notApplied(let scene)?: return ("Scene \(scene) not applied", "The QC stayed on \(sceneTitle(current))", true)
        case .unknown(let scene)?: return ("Switch to Scene \(scene): outcome unknown", "Showing the QC’s scene, \(sceneTitle(current))", true)
        case nil: return nil
        }
    }
}

/// An expression pedal from the side: the base, the tilted treadle and its hinge.
struct PedalGlyph: View {
    var size: CGFloat = 16
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 24
            var path = Path()
            path.move(to: CGPoint(x: 3 * s, y: 20 * s)); path.addLine(to: CGPoint(x: 21 * s, y: 20 * s))
            path.move(to: CGPoint(x: 5.5 * s, y: 16.5 * s)); path.addLine(to: CGPoint(x: 19 * s, y: 9.5 * s))
            path.move(to: CGPoint(x: 17 * s, y: 15 * s)); path.addLine(to: CGPoint(x: 17 * s, y: 20 * s))
            path.addEllipse(in: CGRect(x: 3.9 * s, y: 15.4 * s, width: 3.2 * s, height: 3.2 * s))
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 2 * s, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Under the dial: every scene's value for a scene parameter, one shared row for a global one,
/// or the pedal's sweep. The rows are about the same height, so the tiles below barely move.
struct SceneScopeRow: View {
    @ObservedObject var model: PhoneModel
    let block: PresetSnapshot.Block
    let parameter: String
    let theme: PhoneTheme
    let scope: GenericEditor.Scope
    /// The active scene, or the one being switched to.
    let editingScene: String
    let loading: Bool
    /// The value on its way to the QC for the editing scene.
    let proposed: ParameterValue?
    /// Scenes per row: 8 in one row under a wide dial, 4 × 2 in a narrow column beside it.
    var columns = 8
    private var control: ParameterControl? { model.editor.control(blockID: block.id, parameterID: parameter) }
    private var name: String { control?.name.capitalized ?? "Value" }

    var body: some View {
        switch scope {
        case .scene: strip
        case .global:
            card(title: "Same in every scene", detail: "Switching scene keeps this value") {
                HStack(spacing: 5) { ForEach(0..<8, id: \.self) { SceneDot(color: model.sceneColor(theme, $0), size: 9, theme: theme) } }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name) is shared by all eight scenes")
        case .expression(let pedal):
            card(title: "Expression \(pedal.pedal)", detail: "Assigned on the QC") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Heel"); Text(sweep(pedal.heel)).font(.headline).foregroundStyle(theme.ink)
                    Image(systemName: "arrow.right").font(.caption)
                    Text("Toe"); Text(sweep(pedal.toe)).font(.headline).foregroundStyle(theme.ink)
                }.font(.footnote).foregroundStyle(theme.muted).lineLimit(1).minimumScaleFactor(0.7)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Expression \(pedal.pedal) sweep, heel \(sweep(pedal.heel)) to toe \(sweep(pedal.toe)). Edit the assignment on the QC")
        case .unknown: EmptyView()
        }
    }
    private func sweep(_ wire: Double) -> String { model.format(.number(wire), control: control, unit: false) }

    private var strip: some View {
        let values = model.editor.sceneValues(blockID: block.id, parameterID: parameter)
        let unit = control?.unit ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            let title = Text("\(name) in each scene" + (unit.isEmpty ? "" : " · \(unit)")).fontWeight(.semibold)
            let hint = Text("Switch scene to edit another").lineLimit(1).minimumScaleFactor(0.8)
            Group {
                if columns < 8 {
                    VStack(alignment: .leading, spacing: 2) { title; hint }
                } else {
                    HStack(alignment: .firstTextBaseline) { title; Spacer(minLength: 8); hint }
                }
            }.font(.caption).foregroundStyle(theme.muted).padding(.horizontal, 2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                ForEach(PresetSnapshot.sceneLetters, id: \.self) { letter in
                    cell(letter, value: values[letter])
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) in each scene, read-only. Switch scene to edit another")
    }
    private func cell(_ letter: String, value: ParameterValue?) -> some View {
        let index = PresetSnapshot.sceneLetters.firstIndex(of: letter) ?? 0
        let on = letter == editingScene
        let shown = on && loading ? nil : (on ? proposed ?? value : value)
        let text = shown.map { model.format($0, control: control, unit: false) } ?? "—"
        let shape = RoundedRectangle(cornerRadius: 12)
        let sceneName = model.sceneName(index)
        return VStack(spacing: 4) {
            HStack(spacing: 3) {
                SceneDot(color: model.sceneColor(theme, index), size: 7, theme: theme)
                Text(letter).font(.caption2.weight(on ? .bold : .medium)).foregroundStyle(on ? theme.ink : theme.muted)
            }
            Text(text).font(.footnote.weight(on ? .bold : .medium)).monospacedDigit()
                .foregroundStyle(on ? theme.ink : theme.muted).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(on ? theme.ink.opacity(0.07) : .clear, in: shape)
        .overlay {
            if on && proposed != nil { shape.stroke(theme.signal, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
            else if on { shape.stroke(model.sceneColor(theme, index), lineWidth: 1.5) }
        }
        .overlay(alignment: .bottom) { if !on { theme.line.frame(height: 1).padding(.horizontal, 6) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scene \(letter)\(sceneName.isEmpty ? "" : " \(sceneName)"), \(on && loading ? "loading" : text)\(on ? ", editing" : "")")
    }
    private func card<Trailing: View>(title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        let label = VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(theme.muted)
        }
        // A narrow column beside the dial puts the dots or sweep under the text.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { label; Spacer(minLength: 8); trailing() }
            VStack(alignment: .leading, spacing: 8) { label; trailing() }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 64)
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(theme.line))
    }
}

/// iPhone: the scene in the block editor's navigation bar. It opens a list of the scenes with
/// the selected parameter's value in each; choosing one switches the QC and keeps the block and
/// parameter selected.
struct ScenePill: View {
    @ObservedObject var model: PhoneModel
    let snapshot: PresetSnapshot
    let theme: PhoneTheme
    let blockID: String
    let parameterID: String
    @State private var open = false
    private var scene: String {
        if case .pending(let target)? = model.sceneSwitch { return target }
        return snapshot.scene
    }
    private var scoped: Bool { model.editor.scope(blockID: blockID, parameterID: parameterID) == .scene }
    private var failure: (mark: String, label: String)? {
        switch model.sceneSwitch {
        case .notApplied(let target)?: return ("!", model.sceneAccessibilityLabel(target))
        case .unknown(let target)?: return ("?", "Switch to \(model.sceneTitle(target)): outcome unknown. Showing \(model.sceneTitle(snapshot.scene))")
        default: return nil
        }
    }
    private var control: ParameterControl? { model.editor.control(blockID: blockID, parameterID: parameterID) }

    var body: some View {
        let index = PresetSnapshot.sceneLetters.firstIndex(of: scene) ?? 0
        Button { open = true } label: {
            HStack(spacing: 6) {
                SceneDot(color: model.sceneColor(theme, index), size: 10, theme: theme)
                Text(scene).fontWeight(.bold)
                let name = model.sceneName(index)
                if !name.isEmpty { Text(name.uppercased()).foregroundStyle(theme.muted).lineLimit(1) }
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(theme.muted)
            }
            .font(.subheadline).padding(.horizontal, 6)
            .overlay(alignment: .topTrailing) {
                // A refused or unanswered switch stays marked, as on the overview strip.
                if let failure {
                    Text(failure.mark).font(.caption2.weight(.heavy)).foregroundStyle(theme.signalInk)
                        .frame(width: 18, height: 18).background(theme.caution, in: Circle())
                        .offset(x: 10, y: -10).accessibilityHidden(true)
                }
            }
        }
        .accessibilityLabel(failure?.label ?? model.sceneAccessibilityLabel(scene))
        .accessibilityHint("Shows the scenes. Choosing one switches the QC.")
        .popover(isPresented: $open, arrowEdge: .top) {
            menu.presentationCompactAdaptation(.popover).presentationBackground(theme.surface.opacity(0.95))
        }
    }
    private var menu: some View {
        let values = model.editor.sceneValues(blockID: blockID, parameterID: parameterID)
        let unit = control?.unit ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Scene").fontWeight(.semibold)
                Spacer()
                if scoped { Text((control?.name.capitalized ?? "Value") + (unit.isEmpty ? "" : " \(unit)")) }
            }.font(.caption).foregroundStyle(theme.muted).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
            ForEach(Array(PresetSnapshot.sceneLetters.enumerated()), id: \.offset) { index, letter in
                Button { open = false; model.selectScene(letter) } label: {
                    HStack(spacing: 12) {
                        SceneDot(color: model.sceneColor(theme, index), size: 10, theme: theme)
                        Text(letter).fontWeight(.bold).frame(width: 16, alignment: .leading)
                        Text(model.sceneName(index).uppercased()).foregroundStyle(theme.muted).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        if scoped { Text(values[letter].map { model.format($0, control: control, unit: false) } ?? "—").font(.subheadline).foregroundStyle(theme.muted).monospacedDigit() }
                        Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(theme.signal)
                            .frame(width: 18).opacity(letter == snapshot.scene ? 1 : 0)
                    }
                    .padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.sceneTitle(letter) + (scoped ? ", \(values[letter].map { model.format($0, control: control) } ?? "no value")" : ""))
                .accessibilityAddTraits(letter == snapshot.scene ? .isSelected : [])
            }
            Divider().padding(.top, 4)
            Text("Switches the scene on the QC. \(model.editor.blockName(blockID: blockID) ?? "This block") and \(control?.name.capitalized ?? "this parameter") stay selected.")
                .font(.footnote).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
        }
        .padding(6).frame(width: 300).foregroundStyle(theme.ink)
    }
}
