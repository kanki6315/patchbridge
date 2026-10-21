import SwiftUI

/// The iPhone Duo's screens. No other iPhone is wider than 440 pt, so every regular iPhone
/// returns nil here and keeps the layouts in `EditorView`.
enum DuoScreen: Equatable {
    case inner, outerLandscape, outerPortrait
    /// `window` is the full window size, safe areas included.
    init?(window: CGSize) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return nil }
        let short = min(window.width, window.height)
        if short >= 600 {
            // The inner screen is designed held upright; on its side it keeps the existing layouts.
            guard window.height > window.width else { return nil }
            self = .inner
        } else if short >= 450 {
            self = window.width > window.height ? .outerLandscape : .outerPortrait
        } else { return nil }
    }
}

/// iPhone Duo layouts. Posture changes the layout, never the model or the save rules: the row,
/// selected block and open editor carry across folding, unfolding and rotating.
struct DuoWorkspaceView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var tuner: TunerModel
    let theme: PhoneTheme
    let screen: DuoScreen
    /// The safe-area frame's size and the window's safe-area insets, to place the hinge.
    let size: CGSize
    let insets: EdgeInsets
    @Binding var row: Int
    @Binding var selected: String?
    /// Owned by EditorView so navigation survives the sideways inner-screen fallback.
    @Binding var editing: Bool
    let showConnection: () -> Void
    let openEditor: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// iOS doesn't report hinge posture to the app yet, so the inner screen stays flat. Set this
    /// from the posture signal once there is one.
    @State private var halfFolded = DuoWorkspaceView.launchHalfFolded
    @State private var confirmSave = false
    @State private var saveContext: PresetSnapshot?
    @State private var typingTarget: MenuTarget?
    @State private var typingContext: PresetSnapshot?
    @State private var entry = ""
    private let letters = Array("ABCDEFGH").map(String.init)
    /// Nothing interactive sits within this distance of the fold.
    private let foldGap: CGFloat = 14
    /// With the live tuner on, the crease gets room of its own; the same in both postures, so folding still moves nothing.
    private let creaseGap: CGFloat = 31

    struct MenuTarget: Identifiable {
        let block: String
        let parameter: String
        var id: String { block + "/" + parameter }
    }
    private enum CellStyle { case named, code }

    private static var launchHalfFolded: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--half-folded")
        #else
        return false
        #endif
    }

    var body: some View {
        if let snapshot = model.snapshot {
            Group {
                switch screen {
                case .inner: inner(snapshot)
                case .outerLandscape: VStack(spacing: 0) { outerLine; outerLandscape(snapshot) }
                case .outerPortrait:
                    VStack(spacing: 0) { if column == 0 { outerLine }; outerPortrait(snapshot) }
                        .overlay { if column > 0 { statusColumn } }
                }
            }
            .onAppear {
                if !snapshot.blocks.contains(where: { $0.id == selected }) { editing = false }
            }
            .task {
                #if DEBUG
                // The first root geometry can still describe the folded window at launch.
                // Select the deck only once this actual inner workspace has appeared.
                if model.screenshotFixture, screen == .inner,
                   ProcessInfo.processInfo.arguments.contains("--editor") {
                    try? await Task.sleep(for: .milliseconds(600))
                    selected = "0:1"
                    editing = true
                }
                if model.screenshotFixture, ProcessInfo.processInfo.arguments.contains("--save-confirmation") {
                    try? await Task.sleep(for: .milliseconds(600))
                    requestSave()
                }
                #endif
            }
            #if DEBUG
            .onChange(of: model.previewStep) { _, step in
                if step == 9 { requestSave() }
                if step == 10 {
                    confirmSave = false
                    if saveContext == model.snapshot { model.save() }
                }
            }
            #endif
            .onChange(of: snapshot) { _, value in
                if editing, !value.blocks.contains(where: { $0.id == selected }) { editing = false }
                if let target = typingTarget, !value.blocks.contains(where: { $0.id == target.block }) { typingTarget = nil }
            }
            .sheet(item: $typingTarget) { target in
                NumberPad(theme: theme, control: model.editor.control(blockID: target.block, parameterID: target.parameter), entry: $entry, busy: model.busy,
                          cancel: { typingTarget = nil }, set: { commitTyped(target, $0) })
                    .background(theme.surface)
                    .presentationDetents([.height(355)]).presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: Motion

    /// Folding is one 560 ms ease-out-quint transition; Reduce Motion makes it instant.
    private var foldMotion: Animation? { reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.56) }
    private var motion: Animation? { reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.25) }
    /// The compact scene strip arrives 120 ms into the fold.
    private var stripTransition: AnyTransition { .opacity.animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.44).delay(0.12)) }

    private func select(_ block: PresetSnapshot.Block) {
        selected = block.id; row = block.position[0]
        withAnimation(motion) { editing = true }
    }
    private func closeEditor() { withAnimation(motion) { editing = false } }
    private func requestSave() { saveContext = model.snapshot; confirmSave = true }
    private func confirmCurrentSave() {
        guard saveContext == model.snapshot else {
            model.notice = "Not saved · the preset changed. Review it before saving."; return
        }
        model.save()
    }

    // MARK: Inner screen, flat and half-folded

    /// The view above the hinge and the control deck below it. Only the view changes with the fold.
    private func inner(_ snapshot: PresetSnapshot) -> some View {
        let hinge = (size.height + insets.top + insets.bottom) / 2 - insets.top
        let gap = tuner.live ? creaseGap : foldGap
        return VStack(spacing: 0) {
            innerView(snapshot).frame(height: max(0, hinge - gap))
            fold.frame(height: gap * 2)
                .overlay { if tuner.live { TunerCrease(readout: tuner.readout, theme: theme).transition(.opacity) } }
            deck(snapshot).frame(maxHeight: .infinity, alignment: .top)
        }
        // The crease's light spills over both halves; it never takes a tap.
        .overlay {
            if tuner.live { TunerCreaseLight(readout: tuner.readout, theme: theme, width: size.width, foldY: hinge).transition(.opacity) }
        }
        .animation(motion, value: tuner.live)
    }
    /// The folded screens are phone-sized, so they use the iPhone's tuner line.
    @ViewBuilder private var outerLine: some View {
        if tuner.live {
            TunerLine(readout: tuner.readout, theme: theme) { tuner.setOpen(true) }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    /// Opens the full tuner: a popover on the inner screen, the iPhone's sheet when folded.
    @ViewBuilder private var tunerButton: some View {
        if tuner.available {
            if screen == .inner {
                TunerButton(tuner: tuner, theme: theme) { tuner.setOpen(true) }
                    .popover(isPresented: Binding(get: { tuner.open }, set: { if !$0 { tuner.setOpen(false) } }), arrowEdge: .top) {
                        TunerPopover(tuner: tuner, theme: theme)
                    }
            } else {
                TunerButton(tuner: tuner, theme: theme) { tuner.setOpen(true) }
            }
        }
    }
    private func innerView(_ snapshot: PresetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.name).font(.system(size: halfFolded ? 22 : 30, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                    HStack(spacing: 10) {
                        Text(model.location(snapshot)).foregroundStyle(theme.muted)
                        if snapshot.dirty { unsaved }
                    }.font(.subheadline.weight(.medium))
                }.layoutPriority(1)
                Spacer(minLength: 8)
                if halfFolded { sceneStrip(snapshot, stacked: true).transition(stripTransition) }
                tunerButton
                statusButton(compact: halfFolded)
            }
            if !halfFolded { namedScenes(snapshot).transition(.opacity) }
            grid(snapshot, style: .named, band: !editing, cellHeight: nil).frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 24).padding(.top, 8)
        .animation(foldMotion, value: halfFolded)
    }
    /// A hairline at the hinge, with the crease shadow fading in when half-folded.
    private var fold: some View {
        ZStack {
            LinearGradient(colors: [Color.black.opacity(theme.daylight ? 0.08 : 0.35), .clear], startPoint: .center, endPoint: .top)
                .opacity(halfFolded ? 1 : 0)
            Rectangle().fill(theme.line).frame(height: 1).padding(.horizontal, 24)
        }
        .animation(foldMotion, value: halfFolded)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
    /// The control deck: the row's blocks with Save, or the selected block's dial and controls.
    @ViewBuilder private func deck(_ snapshot: PresetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if editing, let block = snapshot.blocks.first(where: { $0.id == selected }) {
                HStack(spacing: 12) {
                    Button { closeEditor() } label: {
                        Label("Row \(block.position[0] + 1)", systemImage: "chevron.left").font(.headline)
                            .padding(.horizontal, 16).frame(minHeight: 44)
                    }.buttonStyle(.plain).phoneGlass(theme, radius: 22)
                    chip(block, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name(block)).font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.7)
                        Text("\(model.kind(block)) · slot \(block.position[1] + 1)").font(.subheadline).foregroundStyle(theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    BypassButton(model: model, block: block, theme: theme)
                    saveButton(snapshot, short: true)
                }
                notice
                BlockEditorView(model: model, block: block, theme: theme, layout: .deck)
            } else {
                let blocks = snapshot.blocks.filter { $0.position[0] == row }.sorted { $0.position[1] < $1.position[1] }
                HStack(spacing: 12) {
                    Text("Row \(row + 1)").font(.title2.bold())
                    Text("\(blocks.count) blocks · \(8 - blocks.count) empty").foregroundStyle(theme.muted).lineLimit(1)
                    Spacer(minLength: 8)
                    saveButton(snapshot, short: false)
                }
                notice
                ScrollView { rowList(blocks) }
            }
        }
        .padding(.horizontal, 24)
    }
    private func rowList(_ blocks: [PresetSnapshot.Block]) -> some View {
        VStack(spacing: 0) {
            if blocks.isEmpty { Text("No blocks in this row").foregroundStyle(theme.muted).padding(24) }
            ForEach(blocks, id: \.id) { block in
                Button { select(block) } label: {
                    HStack(spacing: 14) {
                        chip(block, size: 40)
                        Text(model.name(block)).font(.headline).lineLimit(1).minimumScaleFactor(0.8).frame(width: 170, alignment: .leading)
                        Text(model.summary(block)).font(.subheadline).foregroundStyle(theme.muted).lineLimit(1)
                        Spacer(minLength: 0)
                        if !model.editable(block) { Image(systemName: "lock").foregroundStyle(theme.muted) }
                        Image(systemName: "chevron.right").foregroundStyle(theme.muted)
                    }.frame(minHeight: 50).padding(.vertical, 2).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Rectangle().fill(theme.line).frame(height: 0.5)
            }
        }
    }

    // MARK: Outer screen

    /// Landscape, the main folded posture: a one-line header over the named grid. The block menu
    /// is a side panel and the grid narrows to codes beside it, so no row is covered.
    private func outerLandscape(_ snapshot: PresetSnapshot) -> some View {
        let menuBlock = editing ? snapshot.blocks.first(where: { $0.id == selected }) : nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                statusButton(compact: true)
                tunerButton
                VStack(alignment: .leading, spacing: 0) {
                    Text(snapshot.name).font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.7)
                    if snapshot.dirty { unsaved.font(.subheadline.weight(.semibold)) }
                }.layoutPriority(1)
                Spacer(minLength: 4)
                sceneStrip(snapshot, stacked: false)
                saveButton(snapshot, short: true)
            }
            notice
            HStack(spacing: 12) {
                grid(snapshot, style: menuBlock == nil ? .named : .code, band: false, cellHeight: nil)
                if let menuBlock {
                    menu(menuBlock, sheet: false)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: 28))
                        .overlay(RoundedRectangle(cornerRadius: 28).stroke(theme.line))
                        .frame(width: 280)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }.frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .animation(motion, value: editing)
    }
    /// Portrait: the whole grid at touch size with codes, scenes as a 4 × 2 set and the save bar,
    /// which floats over the content so the scenes scroll up past it.
    /// The block menu rises as a medium-height panel with no scrim, leaving the top rows visible.
    private func outerPortrait(_ snapshot: PresetSnapshot) -> some View {
        let menuBlock = editing ? snapshot.blocks.first(where: { $0.id == selected }) : nil
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.name).font(.largeTitle.bold()).lineLimit(1).minimumScaleFactor(0.7)
                        HStack(spacing: 10) {
                            Text(model.location(snapshot)).foregroundStyle(theme.muted)
                            if snapshot.dirty { unsaved }
                        }.font(.subheadline.weight(.medium))
                    }.layoutPriority(1)
                    Spacer(minLength: 8)
                    if column == 0 {
                        tunerButton
                        statusButton(compact: false)
                    }
                }
                grid(snapshot, style: .code, band: false, cellHeight: 66)
                sceneGrid(snapshot)
            }.padding(16)
        }.safeAreaInset(edge: .bottom, spacing: 0) { saveBar(snapshot) }
        .overlay(alignment: .bottom) {
            if let menuBlock {
                menu(menuBlock, sheet: true)
                    .padding(.bottom, insets.bottom)
                    .background(theme.surface.opacity(0.97), in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28).stroke(theme.line))
                    .shadow(color: .black.opacity(0.3), radius: 24, y: -4)
                    .ignoresSafeArea(edges: .bottom)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(motion, value: editing)
    }
    /// Portrait's status bar runs down the trailing edge and leaves most of that column empty.
    /// The live tuner and the tuner and connection buttons move into it, so the content keeps its width.
    private var column: CGFloat { screen == .outerPortrait && insets.trailing >= 60 ? insets.trailing : 0 }
    /// The camera, clock and Wi-Fi sit at the top of the column; nothing goes above this.
    private let systemReach: CGFloat = 168
    private var statusColumn: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                if tuner.live {
                    TunerColumn(readout: tuner.readout, theme: theme, window: geometry.size, column: column, top: systemReach)
                        .transition(.opacity)
                }
                // Level with the Save button, within thumb reach.
                VStack(spacing: 12) { tunerButton; statusButton(compact: true) }
                    .frame(width: column).padding(.bottom, insets.bottom + 15)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomTrailing)
        }
        .ignoresSafeArea()
        .animation(motion, value: tuner.live)
    }
    private func saveBar(_ snapshot: PresetSnapshot) -> some View {
        VStack(spacing: 8) {
            if !editing { notice.floatingNote(theme) }
            if model.editor.supports("save") {
                PrimaryButton(title: saveTitle(snapshot), theme: theme) { requestSave() }
                    .floatingDimmed(model.busy || !snapshot.dirty, theme)
                    .saveConfirmation(isPresented: $confirmSave, demo: model.demo, confirm: confirmCurrentSave)
            } else { Label("Read-only connection", systemImage: "lock").font(.footnote).foregroundStyle(theme.muted).floatingNote(theme) }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Block menu

    /// The block, its first four editable controls (− value +, with the value tappable to type)
    /// and Open editor. Tapping another block in the grid swaps its contents.
    private func menu(_ block: PresetSnapshot.Block, sheet: Bool) -> some View {
        let all = model.parameters(block)
        let controls = Array(all.filter { model.editor.readOnlyReason(blockID: block.id, parameterID: $0) == nil }.prefix(4))
        let slot = "Row \(block.position[0] + 1), slot \(block.position[1] + 1)"
        return VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                if sheet {
                    Capsule().fill(theme.muted.opacity(0.5)).frame(width: 36, height: 5)
                        .frame(maxWidth: .infinity).padding(.bottom, 10).accessibilityHidden(true)
                }
                HStack(spacing: 12) {
                    chip(block, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name(block)).font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.7)
                        Text(sheet ? "\(model.kind(block)) · \(slot)" : slot).font(.subheadline).foregroundStyle(theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    BypassButton(model: model, block: block, theme: theme)
                    Button { closeEditor() } label: {
                        Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44).background(theme.raised, in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Close")
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture().onEnded { if sheet && $0.translation.height > 60 { closeEditor() } })
            .padding(.bottom, 6)
            // The portrait menu covers the save bar, so report edit outcomes here.
            if sheet { notice.padding(.bottom, 8) }
            ScrollView {
                VStack(spacing: 0) {
                    if controls.isEmpty { Label("Read-only", systemImage: "lock").foregroundStyle(theme.muted).frame(maxWidth: .infinity, minHeight: 60) }
                    ForEach(controls, id: \.self) { id in
                        menuRow(block, id)
                        Rectangle().fill(theme.line).frame(height: 0.5)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .fixedSize(horizontal: false, vertical: sheet)
            .padding(.bottom, 12)
            Button { openEditor(block.id) } label: {
                HStack(spacing: 8) {
                    Text("Open editor").font(.headline)
                    Spacer(minLength: 4)
                    Text(sheet ? "All \(all.count) controls" : "All \(all.count)").foregroundStyle(theme.muted)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(theme.muted)
                }
                .padding(.horizontal, 20).frame(minHeight: 52).background(theme.raised, in: Capsule()).contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open editor").accessibilityValue("All \(all.count) controls")
        }
        .padding(sheet ? 16 : 14)
        .foregroundStyle(theme.ink)
    }
    private func menuRow(_ block: PresetSnapshot.Block, _ id: String) -> some View {
        let control = model.editor.control(blockID: block.id, parameterID: id)
        let confirmed = model.editor.value(blockID: block.id, parameterID: id) ?? .unknown
        let pending = model.editor.pending.flatMap { $0.blockID == block.id && $0.parameterID == id ? $0 : nil }
        let numeric = control?.displayValue(confirmed) != nil
        let shown = control?.displayValue(pending?.proposedValue ?? confirmed)
        let name = control?.name ?? "value"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(name.capitalized).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                nudgeButton("minus", block, id, -1, name)
                Button { beginTyping(block, id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        if let shown {
                            Text(String(format: "%.1f", shown)).font(.title3.bold()).monospacedDigit()
                            if let unit = control?.unit, !unit.isEmpty { Text(unit).font(.footnote.weight(.semibold)).foregroundStyle(theme.muted) }
                        } else { Text(model.valueText(block.id, id)).font(.headline) }
                    }
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, 4).frame(minWidth: 72, minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(pending != nil ? theme.signal : .clear, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])))
                }
                .buttonStyle(.plain).disabled(!numeric || model.busy)
                .accessibilityLabel("\(name), \(model.valueText(block.id, id))" + (numeric ? ". Enter exact value" : ""))
                nudgeButton("plus", block, id, 1, name)
            }
            if pending != nil, let shown, let current = control?.displayValue(confirmed) {
                Label("Sending \(String(format: "%.1f", shown)) · QC at \(String(format: "%.1f", current))", systemImage: "circle.dotted")
                    .font(.footnote.weight(.semibold)).foregroundStyle(theme.signal)
            }
        }.padding(.vertical, 6)
    }
    private func nudgeButton(_ icon: String, _ block: PresetSnapshot.Block, _ id: String, _ direction: Int, _ name: String) -> some View {
        Button { nudge(block, id, direction) } label: { Image(systemName: icon).font(.headline).frame(width: 44, height: 44) }
            .buttonStyle(.plain).phoneGlass(theme, radius: 22).disabled(model.busy)
            .accessibilityLabel(direction > 0 ? "Increase \(name)" : "Decrease \(name)")
    }
    /// Steps a number by 0.1, as the editor's steppers do, or an option list to its neighbour.
    private func nudge(_ block: PresetSnapshot.Block, _ id: String, _ direction: Int) {
        guard let control = model.editor.control(blockID: block.id, parameterID: id),
              let raw = model.editor.value(blockID: block.id, parameterID: id) else { return }
        if let options = control.options, !options.isEmpty {
            guard case .number(let n) = raw, let index = options.firstIndex(where: { abs($0.value - n) < 0.000001 }),
                  options.indices.contains(index + direction) else { return }
            model.edit(block.id, id, .number(options[index + direction].value))
        } else if let display = control.displayValue(raw), let lo = control.minimum, let hi = control.maximum,
                  let wire = control.wireValue(display: min(hi, max(lo, ((display + 0.1 * Double(direction)) * 10).rounded() / 10))) {
            model.edit(block.id, id, wire)
        } else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private func beginTyping(_ block: PresetSnapshot.Block, _ id: String) {
        guard let display = model.editor.control(blockID: block.id, parameterID: id)?.displayValue(model.editor.value(blockID: block.id, parameterID: id) ?? .unknown) else { return }
        entry = String(format: "%.2f", display); typingContext = model.snapshot
        typingTarget = MenuTarget(block: block.id, parameter: id)
    }
    private func commitTyped(_ target: MenuTarget, _ value: Double) {
        typingTarget = nil
        guard typingContext == model.snapshot else { model.notice = "Not applied · the preset changed while editing"; return }
        guard let wire = model.editor.control(blockID: target.block, parameterID: target.parameter)?.wireValue(display: value) else { return }
        model.edit(target.block, target.parameter, wire)
    }

    // MARK: Shared pieces

    private func grid(_ snapshot: PresetSnapshot, style: CellStyle, band: Bool, cellHeight: CGFloat?) -> some View {
        VStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(0..<8, id: \.self) { column in
                        if let block = snapshot.blocks.first(where: { $0.position == [r, column] }) {
                            Button { select(block) } label: { cell(block, style: style, height: cellHeight) }
                                .buttonStyle(.plain)
                                .accessibilityLabel(model.name(block))
                                .accessibilityAddTraits(editing && selected == block.id ? .isSelected : [])
                        } else {
                            RoundedRectangle(cornerRadius: 12).stroke(theme.line)
                                .frame(maxWidth: .infinity, minHeight: cellHeight, maxHeight: cellHeight ?? .infinity)
                                .contentShape(Rectangle()).onTapGesture { row = r; closeEditor() }
                                .accessibilityHidden(true)
                        }
                    }
                }
                .padding(3)
                .background(band && row == r ? theme.raised : .clear, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(band && row == r ? theme.signal : .clear, lineWidth: 1.5))
            }
        }
        .padding(6).background(theme.surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.line, lineWidth: 1))
    }
    /// A grid cell: the code over up to two lines of the block name, or the code alone.
    private func cell(_ block: PresetSnapshot.Block, style: CellStyle, height: CGFloat?) -> some View {
        let category = model.category(block)
        let bypass = block.scenes[model.snapshot?.scene ?? ""]?.bypass == true
        let chosen = editing && selected == block.id
        return Group {
            if style == .named {
                VStack(alignment: .leading, spacing: 0) {
                    Text(category.code).font(.caption.weight(.bold)).strikethrough(bypass)
                    Spacer(minLength: 2)
                    Text(model.name(block)).font(.caption.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8).multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 7).padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height ?? .infinity, alignment: .leading)
            } else {
                Text(category.code).font(.caption.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6).strikethrough(bypass)
                    .frame(maxWidth: .infinity, minHeight: height, maxHeight: height ?? .infinity)
            }
        }
        .foregroundStyle(bypass ? category.color : (category.darkInk ? Color(hex: 0x161611) : .white))
        .background(bypass ? theme.surface : category.color, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(category.color, style: StrokeStyle(lineWidth: bypass ? 1.5 : 0, dash: [4, 3])))
        .padding(chosen ? 2 : 0)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(chosen ? theme.signal : .clear, lineWidth: 2.5))
    }
    private func chip(_ block: PresetSnapshot.Block, size: CGFloat) -> some View {
        let category = model.category(block)
        return Text(category.code).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.5)
            .foregroundStyle(category.darkInk ? Color(hex: 0x161611) : .white)
            .frame(width: size, height: size).background(category.color, in: RoundedRectangle(cornerRadius: size * 0.27))
    }
    private var unsaved: some View {
        HStack(spacing: 5) { Circle().frame(width: 7, height: 7); Text("Unsaved") }
            .foregroundStyle(theme.signal).accessibilityElement(children: .combine)
    }
    /// The status pill, shrunk to its icon where space is short.
    private func statusButton(compact: Bool) -> some View {
        let title = model.demo ? "Demo preset" : (model.coordinator.macName ?? "Mac connected")
        return Button(action: showConnection) {
            HStack(spacing: 8) {
                Image(systemName: model.demo ? "play.circle" : "checkmark").foregroundStyle(theme.signal)
                if !compact { Text(title).lineLimit(1) }
            }
            .font(.subheadline.weight(.semibold)).padding(.horizontal, compact ? 0 : 16).frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain).phoneGlass(theme, radius: 22)
        .accessibilityLabel(title).accessibilityHint("Connection details")
    }
    private func saveTitle(_ snapshot: PresetSnapshot) -> String {
        if model.demo { return "Save demo preset" }
        guard snapshot.preset_id.hasPrefix("captured:") else { return "Save on the QC" }
        return "Save to " + model.location(snapshot).replacingOccurrences(of: " · ", with: " ")
    }
    @ViewBuilder private func saveButton(_ snapshot: PresetSnapshot, short: Bool) -> some View {
        if model.editor.supports("save") {
            let disabled = model.busy || !snapshot.dirty
            Button { requestSave() } label: {
                Text(short ? "Save" : saveTitle(snapshot)).font(.headline).lineLimit(1).padding(.horizontal, 22).frame(minHeight: 44)
                    .foregroundStyle(theme.signalInk).background(theme.signal, in: Capsule())
            }
            .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
            .saveConfirmation(isPresented: $confirmSave, demo: model.demo, confirm: confirmCurrentSave)
        } else {
            Label("Read-only connection", systemImage: "lock").font(.footnote).foregroundStyle(theme.muted)
        }
    }
    @ViewBuilder private var notice: some View {
        if let message = model.error ?? model.notice ?? model.coordinator.outcome {
            Label(message, systemImage: "info.circle").font(.footnote).foregroundStyle(theme.caution).lineLimit(2)
        } else if let pending = model.editor.pending {
            Label(pending.operation == "save" ? "Saving…" : "Sending…", systemImage: "arrow.triangle.2.circlepath").font(.footnote)
        }
    }
    private func sceneDot(_ index: Int, size: CGFloat) -> some View {
        Circle().fill(model.sceneColor(theme, index)).frame(width: size, height: size)
            .overlay(Circle().stroke(theme.daylight ? theme.ink : .clear, lineWidth: 1))
    }
    /// A named scene cell: dot and letter over the QC's name.
    private func sceneCell(_ snapshot: PresetSnapshot, _ index: Int) -> some View {
        let active = snapshot.scene == letters[index]
        let name = model.sceneName(index)
        return VStack(spacing: 2) {
            HStack(spacing: 6) { sceneDot(index, size: 10); Text(letters[index]).font(.headline) }
            if !name.isEmpty { Text(name.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(active ? theme.ink : theme.muted).lineLimit(1).minimumScaleFactor(0.7) }
        }
        .frame(maxWidth: .infinity).frame(height: 48)
        .background(active ? theme.raised : .clear, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(active ? model.sceneColor(theme, index) : .clear, lineWidth: 1.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scene \(letters[index]) \(name)\(active ? ", active" : "")")
    }
    private func namedScenes(_ snapshot: PresetSnapshot) -> some View {
        HStack(spacing: 4) { ForEach(0..<8, id: \.self) { sceneCell(snapshot, $0) } }
    }
    private func sceneGrid(_ snapshot: PresetSnapshot) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(0..<8, id: \.self) { index in
                sceneCell(snapshot, index).overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line))
            }
        }
    }
    /// The compact strip: the active scene's letter and name, then each scene's dot and letter.
    private func sceneStrip(_ snapshot: PresetSnapshot, stacked: Bool) -> some View {
        let active = letters.firstIndex(of: snapshot.scene) ?? 0
        let name = model.sceneName(active)
        let label = Text((stacked ? "Scene " : "") + snapshot.scene + (name.isEmpty ? "" : " · \(name.uppercased())"))
            .font(.subheadline.weight(.semibold)).lineLimit(1)
        let dots = HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { index in
                VStack(spacing: 2) { sceneDot(index, size: 8); Text(letters[index]).font(.caption2.weight(.semibold)) }
                    .frame(width: 26, height: 36)
                    .background(index == active ? theme.raised : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(index == active ? model.sceneColor(theme, index) : .clear, lineWidth: 1.5))
            }
        }
        return Group {
            if stacked { VStack(alignment: .trailing, spacing: 4) { label; dots } }
            else { HStack(spacing: 10) { label; dots } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scene \(snapshot.scene) \(name), active")
    }
}
