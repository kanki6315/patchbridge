import SwiftUI

/// The preset name in an overview header. With a bridge that lists presets it opens My Presets;
/// otherwise it is plain text.
struct PresetNameButton: View {
    @ObservedObject var model: PhoneModel
    let snapshot: PresetSnapshot
    let theme: PhoneTheme
    var font: Font = .largeTitle.bold()
    var chevron: CGFloat = 26
    let open: () -> Void
    var body: some View {
        if model.canBrowsePresets {
            Button(action: open) {
                HStack(spacing: 10) {
                    Text(snapshot.name).font(font).lineLimit(1).minimumScaleFactor(0.7)
                    Image(systemName: "chevron.down").font(.system(size: chevron * 0.5, weight: .bold))
                        .frame(width: chevron, height: chevron).background(theme.raised, in: Circle())
                        .foregroundStyle(theme.ink)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(snapshot.name).accessibilityHint("Shows your presets")
        } else {
            Text(snapshot.name).font(font).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

/// My Presets: every used slot, the empty slots between them, and the empty run at the end as
/// one row. The loaded slot is the one the QC reports; a tap marks the row until the QC loads it.
struct PresetBrowser: View {
    enum Layout {
        /// iPhone and the Duo's folded screens: a large sheet, other sources below the list.
        case sheet
        /// iPad: a popover from the name, other sources in a column.
        case popover
        /// The Duo's inner screen: the control deck below the fold, sources in a column.
        case deck
    }
    @ObservedObject var model: PhoneModel
    let theme: PhoneTheme
    let layout: Layout
    let close: () -> Void
    @State private var confirming: PresetList.Entry?
    /// The preset this browser asked for. It closes once the QC has it.
    @State private var sentTo: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if layout == .sheet {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle
                        list
                        otherSources
                    }.padding(.bottom, 24)
                }.scrollIndicators(.hidden)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    sourceColumn.frame(width: layout == .deck ? 200 : 180)
                    ScrollView { list }.scrollIndicators(.hidden)
                }
            }
        }
        .foregroundStyle(theme.ink)
        .onAppear { model.openPresets() }
        // Close once the QC has the new preset; the overview takes over from there.
        .onChange(of: model.presetSwitch) { _, change in if let sentTo, change == .loading(sentTo) { close() } }
        .onChange(of: model.snapshot?.preset_id) { _, id in if let sentTo, id == sentTo { close() } }
        .onDisappear { model.coordinator.clearPresetSwitch() }
        .sheet(item: $confirming) { entry in
            UnsavedEditsSheet(model: model, theme: theme, target: entry) { mode in
                confirming = nil
                if let mode { sentTo = entry.preset_id; model.selectPreset(entry.preset_id, mode: mode) }
            }
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Presets").font(layout == .sheet ? .largeTitle.bold() : .title.bold()).lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                if layout != .sheet, let list = model.coordinator.presetList, !model.coordinator.listingPresets {
                    Text("Listed at \(list.listedAt.formatted(date: .omitted, time: .shortened))").font(.subheadline).foregroundStyle(theme.muted)
                }
                if model.coordinator.presetList != nil && !model.coordinator.listingPresets && model.presetSwitch == nil {
                    Button { model.coordinator.listPresets() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise").font(.headline).lineLimit(1).fixedSize().padding(.horizontal, 14).frame(minHeight: 44)
                    }.buttonStyle(.plain).background(theme.surface, in: Capsule()).overlay(Capsule().stroke(theme.line))
                }
                if layout != .popover {
                    Button("Done", action: close).font(.headline).lineLimit(1).fixedSize().padding(.horizontal, 16).frame(minHeight: 44)
                        .buttonStyle(.plain).background(theme.raised, in: Capsule())
                }
            }
            status
        }
    }
    @ViewBuilder private var status: some View {
        let coordinator = model.coordinator
        if let target = model.presetSwitch.flatMap({ model.presetEntry($0.target) }), model.presetSwitchInFlight {
            Label { Text(model.presetSwitch.map { if case .saving = $0 { "Saving, then switching to \(target.name)…" } else { "Switching to \(target.name)…" } } ?? "") }
                icon: { Spinner(theme: theme) }
                .font(.subheadline).foregroundStyle(theme.muted)
        } else if coordinator.listingPresets && coordinator.presetList == nil {
            VStack(alignment: .leading, spacing: 4) {
                Label { Text("Reading the preset list from the QC").font(.headline) } icon: { Spinner(theme: theme) }
                Text("About 12 seconds. Closing this won’t stop it.").font(.subheadline).foregroundStyle(theme.muted)
                SweepBar(theme: theme).padding(.top, 6)
            }
        } else if coordinator.listingPresets {
            Label { Text("Refreshing the list…") } icon: { Spinner(theme: theme) }.font(.subheadline).foregroundStyle(theme.muted)
        } else if let error = coordinator.presetListError {
            HStack(spacing: 12) {
                Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(theme.caution)
                Button("Try again") { coordinator.listPresets() }.font(.subheadline.weight(.semibold)).foregroundStyle(theme.signal)
            }
        } else if layout == .sheet, let list = coordinator.presetList {
            Text("Listed at \(list.listedAt.formatted(date: .omitted, time: .shortened))").font(.subheadline).foregroundStyle(theme.muted)
        }
    }

    // MARK: Sources

    private var countText: String {
        guard let list = model.coordinator.presetList else { return "Reading…" }
        return "\(list.entries.count) of \(list.slots) slots"
    }
    private var sectionTitle: some View {
        HStack {
            Text(model.coordinator.presetList?.source ?? "My Presets").font(.headline)
            Spacer()
            Text(countText).font(.subheadline).foregroundStyle(theme.muted)
        }.padding(.horizontal, 8)
    }
    private static let laterSources = ["Factory Presets", "Downloads", "Plugin presets"]
    /// Other sources come later; they're shown so the list doesn't look like everything.
    private var otherSources: some View {
        VStack(spacing: 0) {
            ForEach(Self.laterSources, id: \.self) { name in
                Rectangle().fill(theme.line).frame(height: 0.5)
                HStack { Text(name).font(.headline); Spacer(); Text("Not yet").font(.subheadline) }
                    .foregroundStyle(theme.muted).padding(.horizontal, 8).frame(minHeight: 52)
                    .accessibilityElement(children: .combine).accessibilityLabel("\(name), not available yet")
            }
        }.padding(.top, 12)
    }
    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.coordinator.presetList?.source ?? "My Presets").font(.headline)
                Text(countText).font(.subheadline).foregroundStyle(theme.muted)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(theme.raised, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityAddTraits(.isSelected)
            ForEach(Self.laterSources, id: \.self) { name in
                VStack(alignment: .leading, spacing: 2) { Text(name).font(.headline); Text("Not yet").font(.subheadline) }
                    .foregroundStyle(theme.muted).padding(16)
                    .accessibilityElement(children: .combine).accessibilityLabel("\(name), not available yet")
            }
        }
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { reader in
            VStack(spacing: 0) {
                if let list = model.coordinator.presetList {
                    ForEach(list.rows) { row in
                        switch row {
                        case .preset(let entry): presetRow(entry)
                        case .empty(let number): emptyRow("\(number)", "Empty")
                        case .emptyRun(let range): emptyRow("", "Slots \(range.lowerBound)–\(range.upperBound) are empty")
                        }
                        if row != list.rows.last { divider }
                    }
                } else {
                    // The first read: the loaded slot at once, the rest a skeleton.
                    if let snapshot = model.snapshot { loadedRow(snapshot); divider }
                    ForEach(0..<8, id: \.self) { index in skeletonRow(index); if index < 7 { divider } }
                }
            }
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 20))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.line))
            .onAppear { if let id = model.snapshot?.preset_id { reader.scrollTo(id, anchor: .center) } }
            .onChange(of: model.coordinator.presetList?.entries.count) { _, _ in
                if let id = model.snapshot?.preset_id { reader.scrollTo(id, anchor: .center) }
            }
        }
    }
    private var divider: some View { Rectangle().fill(theme.line).frame(height: 0.5) }
    private func number(_ text: String) -> some View {
        Text(text).font(.headline.monospacedDigit()).frame(minWidth: 34, alignment: .trailing)
    }
    private func presetRow(_ entry: PresetList.Entry) -> some View {
        let loaded = entry.preset_id == model.snapshot?.preset_id
        let mark = model.presetSwitch?.target == entry.preset_id ? model.presetSwitch : nil
        let pending: Bool = { switch mark { case .pending?, .saving?, .loading?: return true; default: return false } }()
        return Button { choose(entry) } label: {
            HStack(spacing: 14) {
                number("\(entry.number)").foregroundStyle(loaded ? theme.ink : theme.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.title3.weight(.semibold)).lineLimit(1)
                    if let detail = detail(loaded: loaded, mark: mark) { detail }
                }
                Spacer(minLength: 8)
                if loaded { Image(systemName: "checkmark").font(.title3.weight(.semibold)).foregroundStyle(theme.signal) }
            }
            .padding(.horizontal, 16).frame(minHeight: loaded || mark != nil ? 68 : 56)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(loaded ? theme.raised : .clear)
            .overlay {
                if pending { RoundedRectangle(cornerRadius: 12).stroke(theme.signal, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).padding(4) }
                else if case .notApplied? = mark { RoundedRectangle(cornerRadius: 12).stroke(theme.caution, lineWidth: 1.5).padding(4) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.coordinator.presetSwitchAvailable || model.presetSwitchInFlight)
        .id(entry.preset_id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.presetAccessibilityLabel(entry, loaded: loaded, mark: mark))
        .accessibilityAddTraits(loaded ? .isSelected : [])
        .accessibilityHint(loaded ? "" : "Loads this preset on the QC")
    }
    @ViewBuilder private func detail(loaded: Bool, mark: EditorCoordinator.PresetSwitch?) -> (some View)? {
        switch mark {
        case .saving?:
            Label { Text("Saving the current preset first…") } icon: { Spinner(theme: theme, size: 13) }.font(.subheadline.weight(.semibold)).foregroundStyle(theme.signal)
        case .pending?, .loading?:
            Label { Text("Loading on the QC…") } icon: { Spinner(theme: theme, size: 13) }.font(.subheadline.weight(.semibold)).foregroundStyle(theme.signal)
        case .notApplied(_, let message)?:
            Label(message, systemImage: "exclamationmark.triangle").font(.subheadline.weight(.semibold)).foregroundStyle(theme.caution).lineLimit(2)
        case .unknown?:
            Label("Outcome unknown · showing what the QC reports", systemImage: "questionmark.circle").font(.subheadline.weight(.semibold)).foregroundStyle(theme.caution)
        case nil:
            if loaded {
                let dirty = model.snapshot?.dirty == true
                HStack(spacing: 6) {
                    if dirty { Circle().frame(width: 7, height: 7) }
                    Text(dirty ? "Loaded · unsaved edits" : "Loaded")
                }.font(.subheadline.weight(.semibold)).foregroundStyle(dirty ? theme.signal : theme.muted)
            }
        }
    }
    private func loadedRow(_ snapshot: PresetSnapshot) -> some View {
        HStack(spacing: 14) {
            number(snapshot.location.map { "\($0.number)" } ?? "")
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.name).font(.title3.weight(.semibold)).lineLimit(1)
                detail(loaded: true, mark: nil)
            }
            Spacer(minLength: 8)
            Image(systemName: "checkmark").font(.title3.weight(.semibold)).foregroundStyle(theme.signal)
        }
        .padding(.horizontal, 16).frame(minHeight: 68).background(theme.raised)
        .accessibilityElement(children: .combine)
    }
    private func emptyRow(_ number: String, _ text: String) -> some View {
        HStack(spacing: 14) { self.number(number); Text(text).font(.title3) }
            .foregroundStyle(theme.muted).padding(.horizontal, 16).frame(minHeight: 52).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
    private func skeletonRow(_ index: Int) -> some View {
        let widths: [CGFloat] = [130, 175, 105, 150, 120, 165, 95, 140]
        return HStack(spacing: 14) {
            Capsule().fill(theme.raised).frame(width: 34, height: 12)
            Capsule().fill(theme.raised).frame(width: widths[index], height: 14)
            Spacer()
        }
        .padding(.horizontal, 16).frame(height: 52)
        .opacity(1 - Double(index) * 0.09).accessibilityHidden(true)
    }
    private func choose(_ entry: PresetList.Entry) {
        guard let snapshot = model.snapshot else { return }
        if entry.preset_id == snapshot.preset_id { return }
        if snapshot.dirty { confirming = entry } else { sentTo = entry.preset_id; model.selectPreset(entry.preset_id, mode: .clean) }
    }
}

/// Before loading over unsaved edits: what would be lost, and the three ways out.
struct UnsavedEditsSheet: View {
    @ObservedObject var model: PhoneModel
    let theme: PhoneTheme
    let target: PresetList.Entry
    /// nil cancels.
    let finish: (EditorCoordinator.PresetSwitchMode?) -> Void
    var body: some View {
        let edits = model.editor.unsavedEdits
        let name = model.snapshot?.name ?? "This preset"
        VStack(alignment: .leading, spacing: 18) {
            Text("Switch to \(target.name)?").font(.title2.bold())
            Text(edits.isEmpty
                 ? "\(name) has edits that aren’t saved on the QC. Switching anyway loses them."
                 : edits.count == 1 ? "\(name) has 1 edit that isn’t saved on the QC. Switching anyway loses it."
                 : "\(name) has \(edits.count) edits that aren’t saved on the QC. Switching anyway loses them.")
                .foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
            if !edits.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(edits.enumerated()), id: \.offset) { index, edit in
                            if index > 0 { Rectangle().fill(theme.line).frame(height: 0.5) }
                            row(edit)
                        }
                    }
                }
                .frame(maxHeight: 260).fixedSize(horizontal: false, vertical: true)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.line))
            }
            VStack(spacing: 10) {
                if model.editor.supports("save") {
                    PrimaryButton(title: "Save and switch", theme: theme) { finish(.saveFirst) }
                }
                Button { finish(.discard) } label: {
                    Text("Switch anyway").font(.headline).foregroundStyle(theme.danger).frame(maxWidth: .infinity).frame(minHeight: 52)
                        .background(theme.raised, in: Capsule())
                }.buttonStyle(.plain)
                Button { finish(nil) } label: {
                    Text("Cancel").font(.headline).frame(maxWidth: .infinity).frame(minHeight: 52).background(theme.raised, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.ground).foregroundStyle(theme.ink)
        .preferredColorScheme(theme.daylight ? .light : .dark)
    }
    private func row(_ edit: UnsavedEdit) -> some View {
        let block = model.snapshot?.blocks.first { $0.id == edit.blockID }
        let category = block.map(model.category) ?? BlockCategory("")
        return HStack(spacing: 14) {
            Text(category.code).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.5)
                .foregroundStyle(category.darkInk ? Color(hex: 0x161611) : .white)
                .frame(width: 40, height: 40).background(category.color, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(block.map(model.name) ?? "Block").font(.headline).lineLimit(1)
                    if edit.onQC {
                        Text("QC").font(.caption2.weight(.heavy)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(theme.raised, in: RoundedRectangle(cornerRadius: 6)).accessibilityLabel("made on the QC")
                    }
                }
                Text(model.unsavedEditText(edit)).font(.subheadline).foregroundStyle(theme.muted).lineLimit(2)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 14).padding(.vertical, 10).accessibilityElement(children: .combine)
    }
}

/// The overview while a newly loaded preset's metadata arrives: its name and slot over a skeleton.
struct PresetReloadingView: View {
    let snapshot: PresetSnapshot
    let model: PhoneModel
    let theme: PhoneTheme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(snapshot.name).font(.largeTitle.bold()).lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: 10) {
                    Text(model.location(snapshot)).foregroundStyle(theme.muted)
                    Label { Text("Loading from the QC…").fontWeight(.semibold) } icon: { Spinner(theme: theme, size: 14) }
                }.font(.subheadline)
                Capsule().fill(theme.raised).frame(width: 130, height: 18)
                HStack(spacing: 5) { ForEach(0..<8, id: \.self) { _ in RoundedRectangle(cornerRadius: 14).fill(theme.raised).frame(height: 44) } }
                VStack(spacing: 5) {
                    ForEach(0..<4, id: \.self) { _ in
                        HStack(spacing: 4) { ForEach(0..<8, id: \.self) { _ in RoundedRectangle(cornerRadius: 9).fill(theme.raised).frame(height: 38) } }.padding(3)
                    }
                }.padding(8).background(theme.surface, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.line))
                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10).fill(theme.raised).frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 8) {
                            Capsule().fill(theme.raised).frame(width: [150, 118, 170, 96][index], height: 13)
                            Capsule().fill(theme.raised.opacity(0.7)).frame(width: [210, 165, 238, 134][index], height: 9)
                        }
                    }.padding(.vertical, 9)
                }
            }.padding(16).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.name), loading from the QC")
    }
}

/// A turning ring; still with Reduce Motion.
struct Spinner: View {
    let theme: PhoneTheme
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false
    var body: some View {
        Circle().trim(from: 0.1, to: 0.85).stroke(theme.signal, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = !reduceMotion }
            .accessibilityHidden(true)
    }
}

/// An indeterminate bar: the directory arrives in one go, so there's no progress to show.
struct SweepBar: View {
    let theme: PhoneTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * 0.3
            ZStack(alignment: .leading) {
                Capsule().fill(theme.raised)
                Capsule().fill(theme.signal).frame(width: width)
                    .offset(x: reduceMotion ? (geometry.size.width - width) / 2 : phase * (geometry.size.width - width))
            }
        }
        .frame(height: 4)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { phase = 1 }
        }
        .accessibilityHidden(true)
    }
}

extension PhoneModel {
    /// The demo has no QC to list, so the name stays plain text there.
    var canBrowsePresets: Bool { !usesLocalFixture && coordinator.presetBrowsingAvailable }
    var presetSwitch: EditorCoordinator.PresetSwitch? { usesLocalFixture ? nil : coordinator.presetSwitch }
    var presetSwitchInFlight: Bool {
        switch presetSwitch { case .saving?, .pending?, .loading?: return true; default: return false }
    }
    func presetEntry(_ id: String) -> PresetList.Entry? { coordinator.presetList?.entries.first { $0.preset_id == id } }
    /// Reads the list the first time the browser opens; later it's kept until Refresh.
    func openPresets() { if coordinator.presetList == nil { coordinator.listPresets() } }
    func presetAccessibilityLabel(_ entry: PresetList.Entry, loaded: Bool, mark: EditorCoordinator.PresetSwitch?) -> String {
        let base = "\(entry.number), \(entry.name)"
        switch mark {
        case .saving?: return "\(base), saving the current preset first"
        case .pending?, .loading?: return "\(base), loading on the QC"
        case .notApplied(_, let message)?: return "\(base). \(message)"
        case .unknown?: return "\(base), outcome unknown"
        case nil: return loaded ? "\(base), loaded\(snapshot?.dirty == true ? ", unsaved edits" : "")" : base
        }
    }
    /// "Threshold −30.0 dB · saved −34.2 dB", or "Bypassed · saved on". Other scenes say which.
    func unsavedEditText(_ edit: UnsavedEdit) -> String {
        let scene = edit.scene == snapshot?.scene ? "" : "Scene \(edit.scene) · "
        guard let parameter = edit.parameterID else {
            func state(_ value: ParameterValue?) -> String { value == .boolean(true) ? "bypassed" : "on" }
            return scene + state(edit.current).capitalized + " · saved " + state(edit.saved)
        }
        let control = editor.control(blockID: edit.blockID, parameterID: parameter)
        let name = control?.name.capitalized ?? "Value"
        let unit = control?.unit.caseInsensitiveCompare(name) != .orderedSame
        return scene + name + " " + format(edit.current, control: control, unit: unit) + " · saved " + format(edit.saved, control: control, unit: unit)
    }
}
