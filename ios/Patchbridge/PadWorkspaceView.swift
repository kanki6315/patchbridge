import SwiftUI

/// Regular-width layout: grid, row list and a persistent editor panel on one screen.
/// Compact width (Split View, Slide Over, iPhone) keeps the iPhone layout in `EditorView`.
struct PadWorkspaceView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var tuner: TunerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let theme: PhoneTheme
    @State private var row = 0
    @State private var selected: String?
    @State private var confirmSave = false
    @State private var saveContext: PresetSnapshot?
    @State private var details = false
    private let letters = Array("ABCDEFGH").map(String.init)

    var body: some View {
        GeometryReader { geometry in
            let portrait = geometry.size.height > geometry.size.width
            if let snapshot = model.snapshot {
                VStack(alignment: .leading, spacing: 16) {
                    topBar(snapshot, portrait: portrait)
                    // Portrait has no free space in the top bar, so the band takes a row of its own.
                    if portrait && tuner.live {
                        TunerBand(readout: tuner.readout, theme: theme, wide: true) { tuner.setOpen(true) }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if portrait {
                        VStack(alignment: .leading, spacing: 16) {
                            scenes(snapshot)
                            grid(snapshot)
                        }
                        HStack(alignment: .top, spacing: 16) {
                            ScrollView { rowList(snapshot, columns: 1) }
                            panel(snapshot).frame(width: (geometry.size.width - 56) / 2)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 16) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    scenes(snapshot)
                                    grid(snapshot)
                                    rowList(snapshot, columns: 2)
                                }
                            }
                            panel(snapshot).frame(width: min(400, geometry.size.width * 0.34))
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8)
                .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.25), value: tuner.live)
                .onAppear { selectDefault(snapshot) }
                .onChange(of: snapshot) { _, value in selectDefault(value) }
            }
        }
    }

    private func selectDefault(_ snapshot: PresetSnapshot) {
        if let selected, let block = snapshot.blocks.first(where: { $0.id == selected }) { row = block.position[0]; return }
        let ordered = snapshot.blocks.sorted { ($0.position[0], $0.position[1]) < ($1.position[0], $1.position[1]) }
        let block = ordered.first { $0.position[0] == row && model.editable($0) } ?? ordered.first { model.editable($0) } ?? ordered.first
        selected = block?.id
        if let block { row = block.position[0] }
    }
    private func select(_ block: PresetSnapshot.Block) { selected = block.id; row = block.position[0] }

    // MARK: Top bar

    private func topBar(_ snapshot: PresetSnapshot, portrait: Bool) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.name).font(.largeTitle.bold()).lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: 10) {
                    Text(model.location(snapshot)).foregroundStyle(theme.muted)
                    if snapshot.dirty { Label("Unsaved", systemImage: "circle.fill").labelStyle(SmallDotLabel()).foregroundStyle(theme.signal) }
                }.font(.subheadline.weight(.medium))
            }.layoutPriority(1)
            Spacer(minLength: 8)
            // Landscape: the live tuner takes the free space and notices move just below the bar.
            if tuner.live && !portrait { TunerBand(readout: tuner.readout, theme: theme) { tuner.setOpen(true) } } else { toast }
            Spacer(minLength: 8)
            if tuner.available {
                TunerButton(tuner: tuner, theme: theme, size: 48) { tuner.setOpen(true) }
                    .popover(isPresented: Binding(get: { tuner.open }, set: { if !$0 { tuner.setOpen(false) } }), arrowEdge: .top) {
                        TunerPopover(tuner: tuner, theme: theme)
                    }
            }
            // The pill and Save keep their size; the band gives way.
            statusPill.fixedSize()
            saveButton(snapshot).fixedSize()
        }
        .overlay(alignment: .bottom) { if tuner.live && !portrait { toast.offset(y: 60).allowsHitTesting(false) } }
        .zIndex(1)
    }
    /// Notices sit in the top bar's free space, between the preset name and the status pill.
    @ViewBuilder private var toast: some View {
        let pending = model.editor.pending
        if let message = model.error ?? model.notice ?? model.coordinator.outcome ?? pending.map({ $0.operation == "save" ? "Saving on the QC…" : "Sending…" }) {
            let failure = model.error != nil || message.hasPrefix("Not ") || message.hasPrefix("Couldn")
            HStack(spacing: 12) {
                Image(systemName: pending != nil && model.error == nil && model.notice == nil ? "arrow.triangle.2.circlepath" : (failure ? "exclamationmark.triangle" : "info.circle"))
                    .frame(width: 32, height: 32).background(theme.raised, in: Circle())
                Text(message).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            .foregroundStyle(failure ? theme.caution : theme.ink)
            .padding(.leading, 8).padding(.trailing, 18).padding(.vertical, 8)
            .background(theme.surface, in: Capsule()).overlay(Capsule().stroke(theme.line))
            .frame(maxWidth: 380)
            .accessibilityElement(children: .combine)
        }
    }
    private var statusPill: some View {
        let title = model.demo ? "Demo preset" : (model.coordinator.macName ?? "Mac connected")
        return Button { details = true } label: {
            HStack(spacing: 8) {
                Image(systemName: model.demo ? "play.circle" : "checkmark").foregroundStyle(theme.signal)
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(theme.muted)
            }.font(.headline.weight(.medium)).padding(.horizontal, 18).frame(minHeight: 48)
        }
        .buttonStyle(.plain).phoneGlass(theme, radius: 24)
        .accessibilityLabel(title).accessibilityHint("Connection details")
        .popover(isPresented: $details, arrowEdge: .top) {
            PadConnectionDetails(model: model, theme: theme) { details = false }
        }
    }
    private func slotName(_ snapshot: PresetSnapshot) -> String? {
        guard snapshot.preset_id.hasPrefix("captured:") else { return nil }
        return model.location(snapshot).replacingOccurrences(of: " · ", with: " ")
    }
    @ViewBuilder private func saveButton(_ snapshot: PresetSnapshot) -> some View {
        if model.editor.supports("save") {
            let disabled = model.busy || !snapshot.dirty
            Button { saveContext = model.snapshot; confirmSave = true } label: {
                Text(model.demo ? "Save demo preset" : slotName(snapshot).map { "Save to \($0)" } ?? "Save on the QC")
                    .font(.headline).lineLimit(1).padding(.horizontal, 26).frame(minHeight: 48)
                    .foregroundStyle(theme.signalInk).background(theme.signal, in: Capsule())
            }
            .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
            .popover(isPresented: $confirmSave, arrowEdge: .top) { saveConfirmation(snapshot) }
        } else {
            Label("Read-only connection", systemImage: "lock").font(.footnote).foregroundStyle(theme.muted)
        }
    }
    private func saveConfirmation(_ snapshot: PresetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.demo ? "Save this demo preset?" : slotName(snapshot).map { "Save over \($0)?" } ?? "Save on the Quad Cortex?").font(.title3.bold())
            Text(model.demo ? "Changes stay in this demo until you leave it." : "Replaces the saved version on the QC.").foregroundStyle(theme.muted)
            HStack(spacing: 12) {
                Button { confirmSave = false } label: { Text("Cancel").frame(maxWidth: .infinity).frame(minHeight: 48).background(theme.raised, in: Capsule()) }
                Button {
                    confirmSave = false
                    guard saveContext == model.snapshot else {
                        model.notice = "Not saved · the preset changed. Review it before saving."; return
                    }
                    model.save()
                } label: { Text("Save").bold().frame(maxWidth: .infinity).frame(minHeight: 48).foregroundStyle(theme.signalInk).background(theme.signal, in: Capsule()) }
                    .disabled(model.busy)
            }.buttonStyle(.plain).font(.headline)
        }
        .padding(24).frame(width: 360).foregroundStyle(theme.ink)
        .presentationBackground(theme.surface.opacity(0.95))
        .preferredColorScheme(theme.daylight ? .light : .dark)
    }

    // MARK: Scenes and grid

    private func scenes(_ snapshot: PresetSnapshot) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<8, id: \.self) { index in
                let active = snapshot.scene == letters[index]
                let name = model.sceneName(index)
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(model.sceneColor(theme, index)).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(theme.daylight ? theme.ink : .clear, lineWidth: 1))
                        Text(letters[index]).font(.headline)
                    }
                    if !name.isEmpty { Text(name.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(active ? theme.ink : theme.muted).lineLimit(1).minimumScaleFactor(0.7) }
                }
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(active ? theme.raised : .clear, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(active ? model.sceneColor(theme, index) : .clear, lineWidth: 1.5))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Scene \(letters[index]) \(name)\(active ? ", active" : "")")
            }
        }
    }
    private func grid(_ snapshot: PresetSnapshot) -> some View {
        VStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { r in
                HStack(spacing: 6) {
                    Button { row = r } label: { Text("\(r + 1)").font(.footnote.weight(.semibold)).foregroundStyle(theme.muted).frame(width: 18, height: 70) }
                        .buttonStyle(.plain).accessibilityLabel("Row \(r + 1), \(snapshot.blocks.filter { $0.position[0] == r }.count) blocks")
                    HStack(spacing: 6) {
                        ForEach(0..<8, id: \.self) { column in
                            if let block = snapshot.blocks.first(where: { $0.position == [r, column] }) {
                                Button { select(block) } label: { cell(block) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(model.name(block))
                                    .accessibilityAddTraits(selected == block.id ? .isSelected : [])
                            } else {
                                RoundedRectangle(cornerRadius: 12).stroke(theme.line).frame(maxWidth: .infinity).frame(height: 70)
                                    .contentShape(Rectangle()).onTapGesture { row = r }
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .padding(4)
                    .background(row == r ? theme.raised : .clear, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .padding(8).background(theme.surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.line, lineWidth: 1))
    }
    /// Named grid cell: the category code over up to two lines of the block name.
    private func cell(_ block: PresetSnapshot.Block) -> some View {
        let category = model.category(block)
        let bypass = block.scenes[model.snapshot?.scene ?? ""]?.bypass == true
        let ink = bypass ? category.color : (category.darkInk ? Color(hex: 0x161611) : .white)
        return VStack(alignment: .leading, spacing: 0) {
            Text(category.code).font(.caption.weight(.bold)).strikethrough(bypass)
            Spacer(minLength: 2)
            Text(model.name(block)).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 70)
        .background(bypass ? theme.surface : category.color, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(category.color, style: StrokeStyle(lineWidth: bypass ? 1.5 : 0, dash: [4, 3])))
        .padding(selected == block.id ? 2 : 0)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected == block.id ? theme.signal : .clear, lineWidth: 2.5))
    }

    // MARK: Row list and editor panel

    private func rowList(_ snapshot: PresetSnapshot, columns: Int) -> some View {
        let blocks = snapshot.blocks.filter { $0.position[0] == row }.sorted { $0.position[1] < $1.position[1] }
        // Landscape fills the first column top to bottom before the second, like the board.
        let split = (blocks.count + 1) / 2
        let groups = columns == 2 ? [Array(blocks.prefix(split)), Array(blocks.dropFirst(split))] : [blocks]
        return VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Row \(row + 1)").font(.title3.bold()); Spacer(); Text("\(blocks.count) blocks · \(8 - blocks.count) empty").font(.subheadline).foregroundStyle(theme.muted) }
                .padding(.horizontal, 6)
            if blocks.isEmpty { Text("No blocks in this row").foregroundStyle(theme.muted).padding(24) }
            HStack(alignment: .top, spacing: 16) {
                ForEach(groups.indices, id: \.self) { index in
                    VStack(spacing: 4) { ForEach(groups[index], id: \.id) { rowItem($0) } }.frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }.padding(.bottom, 20)
    }
    private func rowItem(_ block: PresetSnapshot.Block) -> some View {
        let category = model.category(block)
        return Button { select(block) } label: {
            HStack(spacing: 14) {
                Text(category.code).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundStyle(category.darkInk ? Color(hex: 0x161611) : .white)
                    .frame(width: 44, height: 44).background(category.color, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name(block)).font(.headline).lineLimit(1)
                    Text(model.summary(block)).font(.subheadline).foregroundStyle(theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !model.editable(block) { Image(systemName: "lock").foregroundStyle(theme.muted) }
            }
            .padding(8).contentShape(Rectangle())
            .background(selected == block.id ? theme.raised : .clear, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected == block.id ? .isSelected : [])
    }
    @ViewBuilder private func panel(_ snapshot: PresetSnapshot) -> some View {
        Group {
            if let block = snapshot.blocks.first(where: { $0.id == selected }) {
                BlockEditorView(model: model, block: block, theme: theme)
            } else {
                Text("Choose a block to edit it here.").foregroundStyle(theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 30))
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(theme.line, lineWidth: 1))
        .padding(.bottom, 12)
    }
}

private struct SmallDotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.font(.system(size: 8)); configuration.title }
    }
}

/// Connection details popover, hanging from the status pill. Appearance pushes inside it.
struct PadConnectionDetails: View {
    @ObservedObject var model: PhoneModel
    let theme: PhoneTheme
    let dismiss: () -> Void
    @AppStorage("appearance") private var appearance = "Stage"
    @AppStorage("matchSystem") private var matchSystem = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Connection").font(.title.bold()).padding(.bottom, 4)
                    section("Bridge") {
                        row("Mac", model.demo ? "Demo · no QC" : (model.coordinator.macName ?? "Connected"))
                        row("Link", model.demo ? "None" : "Bluetooth", ok: !model.demo)
                        if !model.demo { row("Status", model.coordinator.status) }
                        if !model.demo && model.coordinator.trusted { row("Trusted", "Until the Mac app quits") }
                    }
                    section("Available right now") {
                        row("Edit parameters", model.editor.supports("set_parameter") ? "Supported ones" : "Not yet", ok: model.editor.supports("set_parameter"))
                        row("Save to this slot", model.editor.supports("save") ? "Yes" : "Not yet", ok: model.editor.supports("save"))
                        row("Scenes, bypass, Save As", "Not yet")
                    }
                    if model.demo { Text("Edits and saves affect this demo only.").font(.footnote).foregroundStyle(theme.muted) }
                    if !model.demo { ConnectionStatusSettings(model: model, theme: theme).padding(.horizontal, 4) }
                    section("App") {
                        NavigationLink {
                            AppearanceSettings(theme: theme).padding(20)
                                .background(theme.surface.opacity(0.95)).foregroundStyle(theme.ink)
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            HStack {
                                Text("Appearance")
                                Spacer()
                                Text(matchSystem ? "Match \(deviceName)" : appearance)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(theme.muted)
                            }.padding(.horizontal, 16).frame(minHeight: 50).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Appearance")
                    }
                    if !model.demo {
                        Button("Refresh from Mac") { model.coordinator.refresh() }.disabled(model.busy).frame(minHeight: 44)
                    }
                    Button(role: .destructive) { model.disconnect(); dismiss() } label: {
                        Text(model.demo ? "Leave demo" : "Disconnect").font(.headline).foregroundStyle(theme.danger)
                            .frame(maxWidth: .infinity).frame(minHeight: 52).background(theme.raised, in: Capsule())
                    }.buttonStyle(.plain).padding(.top, 8)
                }.padding(20)
            }
            .background(theme.surface.opacity(0.95))
            .toolbar(.hidden, for: .navigationBar)
        }
        .frame(width: 400, height: 620)
        .foregroundStyle(theme.ink).tint(theme.signal)
        .presentationBackground(theme.surface.opacity(0.95))
        .preferredColorScheme(theme.daylight ? .light : .dark)
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.muted).padding(.top, 8)
            VStack(spacing: 0) { content() }
                .background(theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.line))
        }
    }
    private func row(_ title: String, _ value: String, ok: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 12)
            if ok { Image(systemName: "checkmark").foregroundStyle(theme.signal) }
            Text(value).foregroundStyle(ok ? theme.ink : theme.muted).lineLimit(2).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).frame(minHeight: 50)
        .accessibilityElement(children: .combine)
    }
}

/// Loading draws a skeleton of the split layout while the preset is read.
struct PadLoadingView: View {
    let theme: PhoneTheme
    let cancel: () -> Void
    var body: some View {
        GeometryReader { geometry in
            let portrait = geometry.size.height > geometry.size.width
            let skeleton = theme.raised.opacity(0.7)
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 14).fill(skeleton).frame(width: 240, height: 30)
                        RoundedRectangle(cornerRadius: 8).fill(skeleton).frame(width: 150, height: 14)
                    }
                    Spacer()
                    Capsule().fill(skeleton).frame(width: 150, height: 44)
                    Capsule().fill(skeleton).frame(width: 230, height: 48)
                }
                let left = VStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 18).fill(skeleton).frame(height: 52)
                    RoundedRectangle(cornerRadius: 22).fill(skeleton).frame(height: 330)
                    ForEach(0..<3, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 16).fill(skeleton.opacity(1 - Double(index) * 0.25)).frame(height: 52)
                    }
                }
                let reading = VStack(spacing: 16) {
                    ProgressView().tint(theme.signal)
                    Text("Reading the QC…").font(.headline)
                    Button("Cancel", action: cancel).frame(minHeight: 44)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(skeleton, in: RoundedRectangle(cornerRadius: 30))
                if portrait {
                    left.frame(maxHeight: .infinity, alignment: .top)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        left.frame(maxHeight: .infinity, alignment: .top)
                        reading.frame(width: min(400, geometry.size.width * 0.34))
                    }
                }
                if portrait { reading.frame(height: 160) }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
            .accessibilityElement(children: .contain)
        }
    }
}
