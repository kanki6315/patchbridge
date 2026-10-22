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
