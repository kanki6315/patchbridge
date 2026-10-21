import SwiftUI

struct BlockEditorView: View {
    @ObservedObject var model: PhoneModel
    let block: PresetSnapshot.Block
    let theme: PhoneTheme
    /// `deck` is the iPhone Duo's control deck: dial left, tiles or number pad right, no header.
    enum Layout { case standard, deck }
    var layout: Layout = .standard
    @State private var parameter = ""
    @State private var draft: Double?
    @State private var fine = false
    @State private var gestureStart: Date?
    @State private var typing = false
    @State private var entry = ""
    @State private var lastStep: Double?
    @State private var editingContext: PresetSnapshot?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .body) private var unitSize: CGFloat = 18
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 48
    private var control: ParameterControl? { model.editor.control(blockID: block.id, parameterID: parameter) }
    private var raw: ParameterValue { model.editor.value(blockID: block.id, parameterID: parameter) ?? .unknown }
    private var display: Double? { control?.displayValue(raw) }
    private var readOnly: Bool { model.editor.readOnlyReason(blockID: block.id, parameterID: parameter) != nil }
    private var pending: GenericEditor.Pending? {
        guard let p = model.editor.pending, p.blockID == block.id, p.parameterID == parameter else { return nil }; return p
    }
    private var shown: Double? { draft ?? pending?.proposedValue.flatMap { control?.displayValue($0) } ?? display }
    private var category: BlockCategory { model.category(block) }
    private var arcColor: Color { category.arc(daylight: theme.daylight) }
    /// Regular width (iPad) shows the number pad as a popover and types into the dial itself.
    private var regular: Bool { sizeClass == .regular }
    /// The deck shows the number pad beside the dial instead of in a sheet or popover.
    private var inlinePad: Bool { layout == .deck }
    private var subtitle: String {
        let kind = model.kind(block)
        let slot = regular && block.position.count == 2 ? " · Row \(block.position[0] + 1), slot \(block.position[1] + 1)" : ""
        return kind + slot + " · Scene \(model.snapshot?.scene ?? "")"
    }

    var body: some View {
        content
        .background {
            category.color.opacity(theme.daylight ? 0.025 : 0.035)
            RadialGradient(colors: [category.color.opacity(theme.daylight ? 0.06 : 0.13), .clear], center: UnitPoint(x: 0.5, y: 0.35), startRadius: 30, endRadius: 260)
        }
        .onAppear { selectInitial() }
        .task {
            #if DEBUG
            if model.screenshotFixture, ProcessInfo.processInfo.arguments.contains("--exact-value") {
                try? await Task.sleep(for: .milliseconds(600))
                editingContext = model.snapshot
                entry = "-30.00"
                typing = true
            }
            #endif
        }
        #if DEBUG
        .task(id: model.previewStep) {
            guard model.screenshotFixture, model.previewStep == 1, block.id == "0:1",
                  ProcessInfo.processInfo.arguments.contains("--preview-story") else { return }
            // Exercise the native dial's draft/commit path, just like a drag and release.
            do {
                try await Task.sleep(for: .milliseconds(450))
                editingContext = model.snapshot
                let start = display ?? -34.2
                for frame in 0...60 {
                    try Task.checkCancellation()
                    let progress = Double(frame) / 60
                    draft = ((start + (-25.8 - start) * sin(progress * .pi / 2)) * 10).rounded() / 10
                    try await Task.sleep(for: .milliseconds(30))
                }
                commitContextual(-25.8)
                draft = nil
            } catch { draft = nil }
        }
        .onChange(of: model.previewStep) { _, step in
            guard block.id == "0:1" else { return }
            if step == 2 { editingContext = model.snapshot; entry = ""; typing = true }
            if step == 3 { entry = "-3" }
            if step == 4 { entry = "-30.00" }
            if step == 5 { commitContextual(-30); typing = false }
        }
        #endif
        .onChange(of: block.id) { _, _ in selectInitial(); typing = false }
        .onChange(of: model.snapshot) { _, _ in draft = nil; fine = false }
        .sheet(isPresented: Binding(get: { typing && !regular && !inlinePad }, set: { typing = $0 })) { numberPad.presentationDetents([.height(dynamicTypeSize.isAccessibilitySize ? 550 : 355)]).presentationDragIndicator(.visible) }
    }
    @ViewBuilder private var content: some View {
        if layout == .deck {
            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 8) { parameterControl }.frame(maxWidth: .infinity)
                    Group {
                        if typing {
                            numberPad.background(theme.surface, in: RoundedRectangle(cornerRadius: 28))
                                .overlay(RoundedRectangle(cornerRadius: 28).stroke(theme.line))
                        } else { tiles }
                    }.frame(maxWidth: .infinity)
                }.padding(.vertical, 8)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        // Bypassed blocks match the grid: dashed outline and struck-through code.
                        let off = model.editor.bypassed(blockID: block.id) == true
                        Text(category.code).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.4).strikethrough(off)
                            .foregroundStyle(off ? category.color : (category.darkInk ? Color.black : .white)).frame(width: 44, height: 44)
                            .background(off ? theme.surface : category.color, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(category.color, style: StrokeStyle(lineWidth: off ? 1.5 : 0, dash: [4, 3])))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.name(block)).font(.title.bold())
                            Text(subtitle).font(.subheadline).foregroundStyle(theme.muted)
                        }
                        Spacer(minLength: 8)
                        BypassButton(model: model, block: block, theme: theme)
                    }
                    parameterControl
                    tiles
                }.padding(16)
            }
        }
    }
    /// The selected parameter's name, dial or options, and its status line.
    @ViewBuilder private var parameterControl: some View {
        Text(control?.name.capitalized ?? "Parameter").font(.title2.bold()).frame(maxWidth: .infinity)
        if let options = control?.options, !options.isEmpty {
            VStack(spacing: 12) {
                ForEach(options, id: \.value) { option in
                    Button { model.edit(block.id, parameter, .number(option.value)) } label: {
                        HStack { Text(option.label); Spacer(); if raw == .number(option.value) { Image(systemName: "checkmark") } }
                            .font(.headline).padding(24).background(raw == .number(option.value) ? category.color.opacity(0.22) : theme.raised, in: RoundedRectangle(cornerRadius: 18))
                    }.disabled(readOnly || model.busy)
                }
            }.padding(.vertical, 16)
        } else { gauge }
        if readOnly {
            Label(readOnlyText, systemImage: "lock").font(.footnote).foregroundStyle(theme.muted).frame(maxWidth: .infinity)
        } else if pending != nil {
            Text("Sending…").font(.footnote).foregroundStyle(theme.signal).frame(maxWidth: .infinity)
        }
    }
    private func selectInitial() {
        parameter = model.parameters(block).first(where: { model.editor.readOnlyReason(blockID: block.id, parameterID: $0) == nil }) ?? model.parameters(block).first ?? ""
        draft = nil
    }
    private func tileValue(_ id: String) -> String {
        switch model.editor.control(blockID: block.id, parameterID: id)?.kind {
        case "meter": return "Meter"
        case "unknown" where model.editor.readOnlyReason(blockID: block.id, parameterID: id) != nil: return "Scale unknown"
        default: return model.valueText(block.id, id)
        }
    }
    private var readOnlyText: String {
        if control?.kind == "unknown" { return "Read-only · scale unknown" }
        if control?.kind == "meter" { return "Read-only · meter on the QC" }
        return model.editor.readOnlyReason(blockID: block.id, parameterID: parameter) ?? "Read-only"
    }
    private func position(_ value: Double?) -> Double {
        if let value, let control {
            // Arc travel follows the normalized QC knob, including nonlinear scales.
            if control.encoding == "qc_normalized", case .number(let n) = control.wireValue(display: value) { return min(1, max(0, n)) }
            if let lo = control.minimum, let hi = control.maximum, hi > lo { return min(1, max(0, (value - lo) / (hi - lo))) }
        }
        if case .number(let n) = raw, (0...1).contains(n) { return n }
        return 0
    }
    private var gauge: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                DialArc(end: 1).stroke(theme.raised, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                DialArc(end: position(display)).stroke(readOnly ? theme.muted : arcColor, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                if draft != nil || pending != nil {
                    DialArc(start: min(position(display), position(shown)), end: max(position(display), position(shown)))
                        .stroke(theme.signal, style: StrokeStyle(lineWidth: 16, lineCap: .butt, dash: [4, 5]))
                }
                GeometryReader { geo in
                    let angle = (135 + position(shown) * 270) * .pi / 180
                    let radius = (geo.size.width - 26) / 2
                    Circle().fill(readOnly ? theme.ground : (fine ? theme.signal : .white))
                        .overlay(Circle().stroke(readOnly ? theme.muted : theme.ground, lineWidth: 3))
                        .frame(width: 26, height: 26)
                        .position(x: geo.size.width / 2 + radius * cos(angle), y: geo.size.height / 2 + radius * sin(angle))
                }.allowsHitTesting(false)
                VStack(spacing: 10) {
                    Button {
                        editingContext = model.snapshot
                        entry = String(format: "%.2f", display ?? 0); typing = true
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            if readOnly { Image(systemName: "lock").font(.title3) }
                            Text(typingInDial ? (entry.isEmpty ? "0" : entry) : shown.map { String(format: fine ? "%.2f" : "%.1f", $0) } ?? model.valueText(block.id, parameter))
                                .font(.system(size: min(valueSize, fine ? 40 : 48), weight: .bold)).monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
                            if shown != nil { Text(control?.unit ?? "").font(.system(size: min(unitSize, 22), weight: .semibold)).foregroundStyle(theme.muted) }
                        }.padding(5).overlay {
                            if typingInDial {
                                RoundedRectangle(cornerRadius: 12).stroke(enteredValue == nil ? theme.caution : theme.signal, lineWidth: 2)
                            } else {
                                RoundedRectangle(cornerRadius: 12).stroke(pending != nil ? theme.signal : .clear, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                            }
                        }
                    }.buttonStyle(.plain).disabled(readOnly || model.busy || display == nil)
                        .popover(isPresented: Binding(get: { typing && regular && !inlinePad }, set: { typing = $0 }), arrowEdge: .top) {
                            numberPad.frame(width: 340).presentationBackground(theme.surface.opacity(0.95))
                        }
                        .accessibilityLabel("\(control?.name ?? "Value"), \(model.valueText(block.id, parameter)). Enter exact value")
                    if fine { Text("Fine · 0.05 steps").font(.footnote).foregroundStyle(theme.signal) }
                }.padding(.horizontal, 20)
            }
            .frame(width: 240, height: 240)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                guard !readOnly, !model.busy, let control, let lo = control.minimum, let hi = control.maximum else { return }
                if gestureStart == nil {
                    guard hypot(event.startLocation.x - 120, event.startLocation.y - 120) > 85 else { return }
                    gestureStart = Date(); editingContext = model.snapshot
                }
                let dx = event.location.x - 120, dy = event.location.y - 120
                let outward = hypot(dx, dy) > 132
                let newFine = outward && Date().timeIntervalSince(gestureStart!) > 0.35
                if newFine != fine { fine = newFine; UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
                var angle = atan2(dy, dx) * 180 / .pi - 135
                if angle < 0 { angle += 360 }
                // The dead zone below the dial snaps to its nearest endpoint.
                let normalized = angle > 270 ? (angle > 315 ? 0.0 : 1.0) : angle / 270
                let mapped = control.encoding == "qc_normalized" ? control.displayValue(.number(normalized)) : lo + (hi - lo) * normalized
                guard let mapped else { return }
                let step = fine ? 0.05 : 0.1
                let value = min(hi, max(lo, (mapped / step).rounded() * step))
                if value != lastStep { UISelectionFeedbackGenerator().selectionChanged(); lastStep = value }
                draft = value
            }.onEnded { _ in
                if let draft { commitContextual(draft) }
                draft = nil; fine = false; gestureStart = nil; lastStep = nil
            })
            .accessibilityElement(children: .contain)
            .accessibilityAdjustableAction { direction in
                if !readOnly && !model.busy, let display { step(direction == .increment ? 0.1 : -0.1, from: display) }
            }
            HStack(alignment: .bottom) {
                if !readOnly { stepButton("minus", -0.1) }
                Text(control?.minimum.map { String(format: "%g", $0) } ?? "0 %").font(.footnote).foregroundStyle(theme.muted)
                Spacer()
                Text(control?.maximum.map { String(format: "%g", $0) } ?? "100 %").font(.footnote).foregroundStyle(theme.muted)
                if !readOnly { stepButton("plus", 0.1) }
            }.offset(y: 12)
        }.frame(maxWidth: .infinity).padding(.top, 6).padding(.bottom, 30)
    }
    private func stepButton(_ icon: String, _ delta: Double) -> some View {
        Button { if let display { step(delta, from: display) } } label: { Image(systemName: icon).font(.title2).frame(width: 54, height: 54) }.phoneGlass(theme, radius: 27).disabled(model.busy || display == nil)
            .accessibilityLabel(delta > 0 ? "Increase \(control?.name ?? "value")" : "Decrease \(control?.name ?? "value")")
    }
    private func step(_ delta: Double, from value: Double) {
        guard let lo = control?.minimum, let hi = control?.maximum else { return }
        commit(min(hi, max(lo, ((value + delta) * 10).rounded() / 10)))
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private func commitContextual(_ value: Double) {
        guard editingContext == model.snapshot else {
            model.notice = "Not applied · the preset changed while editing"; return
        }
        commit(value)
    }
    private func commit(_ value: Double) {
        guard let wire = control?.wireValue(display: value) else { return }
        model.edit(block.id, parameter, wire)
    }
    private var tiles: some View {
        LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
            ForEach(model.parameters(block), id: \.self) { id in
                let locked = model.editor.readOnlyReason(blockID: block.id, parameterID: id) != nil
                Button { parameter = id; draft = nil } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 3) {
                            if locked { Image(systemName: "lock").font(.caption) }
                            Text(model.editor.control(blockID: block.id, parameterID: id)?.name.capitalized ?? "Parameter \(id)").font(.footnote).lineLimit(1)
                        }.foregroundStyle(theme.muted)
                        Text(tileValue(id)).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(10)
                        .background(parameter == id ? category.color.opacity(0.22) : (locked ? theme.raised.opacity(0.35) : .clear), in: RoundedRectangle(cornerRadius: 18))
                        .parameterMaterial(theme, enabled: !locked)
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(parameter == id ? category.color : theme.line, lineWidth: parameter == id ? 1.5 : 1))
                }.buttonStyle(.plain).disabled(model.editor.pending != nil)
            }
        }
    }
    private var typingInDial: Bool { typing && (regular || inlinePad) }
    private var enteredValue: Double? { NumberPad.value(entry, control) }
    private var numberPad: some View {
        NumberPad(theme: theme, control: control, entry: $entry, showsEntry: !regular && !inlinePad, busy: model.busy,
                  cancel: { typing = false }, set: { commitContextual($0); typing = false })
            .background(regular || inlinePad ? Color.clear : theme.surface)
    }
}

/// The signed number pad: the iOS decimal pad has no minus key. Nothing is sent until Set.
struct NumberPad: View {
    let theme: PhoneTheme
    let control: ParameterControl?
    @Binding var entry: String
    /// Shows the typed value above the keys when the value itself isn't visible.
    var showsEntry = true
    var busy = false
    let cancel: () -> Void
    let set: (Double) -> Void
    static func value(_ entry: String, _ control: ParameterControl?) -> Double? {
        guard let n = Double(entry), n.isFinite, control?.wireValue(display: n) != nil else { return nil }; return n
    }
    private var enteredValue: Double? { NumberPad.value(entry, control) }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                Text("\(control?.minimum.map { String(format: "%g", $0) } ?? "") to \(control?.maximum.map { String(format: "%g", $0) } ?? "") \(control?.unit ?? "")").font(.footnote).foregroundStyle(enteredValue == nil ? theme.caution : theme.muted)
            }
            if showsEntry {
                Text(entry.isEmpty ? "0" : entry).font(.largeTitle.bold()).monospacedDigit().frame(maxWidth: .infinity).padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(enteredValue == nil ? theme.caution : theme.signal, lineWidth: 2)).accessibilityLabel("Entered value \(entry)")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                ForEach(["1", "2", "3", "⌫", "4", "5", "6", "±", "7", "8", "9", ".", "0", "Clear", "Set"], id: \.self) { key in
                    Button { press(key) } label: { Text(key).font(.title3.weight(.semibold)).frame(maxWidth: .infinity).frame(minHeight: 44).background(key == "Set" ? theme.signal : theme.raised, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(key == "Set" ? theme.signalInk : theme.ink) }
                        .disabled(key == "Set" && (enteredValue == nil || busy))
                        .opacity(key == "Set" && enteredValue == nil ? 0.4 : 1)
                        .accessibilityLabel(key == "⌫" ? "Delete" : key == "±" ? "Change sign" : key)
                }
            }
        }.padding(20).foregroundStyle(theme.ink).tint(theme.signal)
    }
    private func press(_ key: String) {
        switch key {
        case "Set": if let value = enteredValue { set(value) }
        case "Clear": entry = ""
        case "⌫": if !entry.isEmpty { entry.removeLast() }
        case "±": if entry.hasPrefix("-") { entry.removeFirst() } else { entry = "-" + entry }
        case ".": if !entry.contains(".") { entry += "." }
        default: if entry.count < 14 { entry += key }
        }
    }
}

private struct DialArc: Shape {
    var start: Double = 0
    var end: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: (min(rect.width, rect.height) - 26) / 2, startAngle: .degrees(135 + start * 270), endAngle: .degrees(135 + end * 270), clockwise: false)
        return path
    }
}

/// Turns the block on or off for the active scene, like the QC's footswitch. Shown only when the
/// bridge advertises bypass writes; the confirmed readback, not the tap, decides what it shows.
struct BypassButton: View {
    @ObservedObject var model: PhoneModel
    let block: PresetSnapshot.Block
    let theme: PhoneTheme
    private var bypassed: Bool? { model.editor.bypassed(blockID: block.id) }
    private var pending: Bool {
        model.editor.pending.map { $0.operation == "set_bypass" && $0.blockID == block.id } ?? false
    }
    var body: some View {
        if model.editor.bypassReadOnlyReason(blockID: block.id) == nil, let bypassed {
            let color = model.category(block).color
            Button { model.setBypass(block.id, !bypassed) } label: {
                Label(bypassed ? "Off" : "On", systemImage: "power").font(.headline)
                    .foregroundStyle(bypassed ? theme.muted : color)
                    .padding(.horizontal, 14).frame(minHeight: 44)
                    .overlay(Capsule().stroke(bypassed ? theme.line : color, style: StrokeStyle(lineWidth: 1.5, dash: pending ? [4, 3] : [])))
            }
            .buttonStyle(.plain).disabled(model.busy)
            .accessibilityLabel("Block \(bypassed ? "off" : "on")")
            .accessibilityHint(bypassed ? "Turns the block on for this scene" : "Bypasses the block for this scene")
        }
    }
}
