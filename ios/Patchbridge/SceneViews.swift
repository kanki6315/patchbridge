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
            HStack(alignment: .firstTextBaseline) {
                Text("\(name) in each scene" + (unit.isEmpty ? "" : " · \(unit)")).fontWeight(.semibold)
                Spacer(minLength: 8)
                Text("Switch scene to edit another").lineLimit(1).minimumScaleFactor(0.8)
            }.font(.caption).foregroundStyle(theme.muted).padding(.horizontal, 2)
            HStack(spacing: 4) {
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(theme.muted)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 64)
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
