import SwiftUI

struct EditorView: View {
    @ObservedObject var model: PhoneModel
    @AppStorage("patchbridge.phoneName") private var phoneName = ""
    @AppStorage("appearance") private var appearance = "Stage"
    @AppStorage("matchSystem") private var matchSystem = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var row = 0
    @State private var selectedBlock: String?
    @State private var inspectedBlock: String?
    // The inner screen temporarily uses the standard layout when rotated sideways.
    // Keep Duo navigation here so removing its workspace does not reset it.
    @State private var duoRow = 0
    @State private var duoSelected: String?
    @State private var duoEditing = false
    @State private var sheet: Sheet?
    @State private var confirmSave = false
    @State private var saveContext: PresetSnapshot?
    @State private var didConfigurePreview = false
    @State private var linkCopied = false
    enum Sheet: String, Identifiable { case connection, appearance, getMac; var id: String { rawValue } }
    private var theme: PhoneTheme { PhoneTheme(daylight: matchSystem ? systemScheme == .light : appearance == "Daylight") }
    /// Regular width uses the iPad workspace; accessibility text sizes keep the roomier iPhone layout.
    private var pad: Bool { sizeClass == .regular && !dynamicTypeSize.isAccessibilitySize }
    private let macURL = URL(string: "https://patchbridge.arjunakankipati.com/appstorelink")!

    var body: some View {
        NavigationStack {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height && !dynamicTypeSize.isAccessibilitySize
            let duo = duoScreen(geometry)
            Group {
                if model.ready, model.snapshot != nil, let duo {
                    DuoWorkspaceView(model: model, theme: theme, screen: duo, size: geometry.size, insets: geometry.safeAreaInsets,
                                     row: $duoRow, selected: $duoSelected, editing: $duoEditing,
                                     showConnection: { sheet = .connection }, openEditor: { selectedBlock = $0 })
                } else if model.ready, model.snapshot != nil, pad {
                    PadWorkspaceView(model: model, theme: theme)
                } else if model.ready, let snapshot = model.snapshot {
                    VStack(spacing: 0) {
                        if landscape {
                            landscapeOverview(snapshot)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    header(snapshot)
                                    scenes(snapshot)
                                    grid(snapshot)
                                    rowList(snapshot)
                                }.padding(16)
                            }
                        }
                        if !landscape { saveBar(snapshot) }
                    }
                } else if pad && duo == nil && model.coordinator.phase == .loading {
                    PadLoadingView(theme: theme) { model.disconnect() }
                } else { connection }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.ground.ignoresSafeArea())
            .foregroundStyle(theme.ink).tint(theme.signal)
            .preferredColorScheme(matchSystem ? nil : (theme.daylight ? .light : .dark))
            .sheet(item: $sheet) { item in
                NavigationStack {
                    sheetContent(item).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(theme.ground).foregroundStyle(theme.ink)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
                }.tint(theme.signal).preferredColorScheme(theme.daylight ? .light : .dark)
            }
            .confirmationDialog(model.demo ? "Save this demo preset?" : "Save on the Quad Cortex?", isPresented: $confirmSave, titleVisibility: .visible) {
                Button(model.demo ? "Save demo preset" : "Save preset") { confirmCurrentSave() }
            } message: { Text(model.demo ? "Changes stay in this demo until you leave it." : "This replaces the saved values of the current preset on the QC.") }
            .onChange(of: model.ready) { _, ready in
                if !ready { selectedBlock = nil; duoRow = 0; duoSelected = nil; duoEditing = false }
            }
            .onChange(of: pad) { _, pad in if pad, duo == nil { selectedBlock = nil } }
            // Folding or unfolding pops a pushed editor; the Duo deck or block menu keeps the block open.
            .onChange(of: duo == .inner) { _, _ in selectedBlock = nil }
            .onAppear {
                #if DEBUG
                guard !didConfigurePreview else { return }
                didConfigurePreview = true
                if ProcessInfo.processInfo.arguments.contains("--stage") { appearance = "Stage"; matchSystem = false }
                let arguments = ProcessInfo.processInfo.arguments
                if let flag = arguments.firstIndex(of: "--activity"), arguments.indices.contains(flag + 1) {
                    model.liveActivity.preview(arguments[flag + 1], daylight: arguments.contains("--daylight"))
                }
                if ProcessInfo.processInfo.arguments.contains("--demo") {
                    model.loadDemo()
                    if ProcessInfo.processInfo.arguments.contains("--editor") && !pad { selectedBlock = "0:1" }
                    if ProcessInfo.processInfo.arguments.contains("--daylight") { appearance = "Daylight" }
                }
                #endif
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $selectedBlock) { id in
            if let snapshot = model.snapshot, let block = snapshot.blocks.first(where: { $0.id == id }) {
                VStack(spacing: 0) {
                    BlockEditorView(model: model, block: block, theme: theme)
                    saveBar(snapshot)
                }
                .background(theme.ground.ignoresSafeArea()).foregroundStyle(theme.ink).tint(theme.signal)
                .navigationTitle(snapshot.name).navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbarBackground(theme.ground, for: .navigationBar)
                .preferredColorScheme(matchSystem ? nil : (theme.daylight ? .light : .dark))
                .confirmationDialog(model.demo ? "Save this demo preset?" : "Save on the Quad Cortex?", isPresented: $confirmSave, titleVisibility: .visible) {
                    Button(model.demo ? "Save demo preset" : "Save preset") { confirmCurrentSave() }
                } message: { Text(model.demo ? "Changes stay in this demo until you leave it." : "This replaces the saved values of the current preset on the QC.") }
            }
        }
        }
    }
    /// The iPhone Duo screen this window is on, if any. Accessibility text sizes keep the iPhone layout.
    private func duoScreen(_ geometry: GeometryProxy) -> DuoScreen? {
        guard !dynamicTypeSize.isAccessibilitySize else { return nil }
        let insets = geometry.safeAreaInsets
        return DuoScreen(window: CGSize(width: geometry.size.width + insets.leading + insets.trailing,
                                        height: geometry.size.height + insets.top + insets.bottom))
    }
    private func requestSave() { saveContext = model.snapshot; confirmSave = true }
    private func confirmCurrentSave() {
        guard saveContext == model.snapshot else {
            model.notice = "Not saved · the preset changed. Review it before saving."; return
        }
        model.save()
    }
    private func header(_ snapshot: PresetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { sheet = .connection } label: {
                    Label(model.demo ? "Demo preset" : (model.coordinator.macName ?? "Mac connected"), systemImage: model.demo ? "play.circle" : "checkmark")
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(minHeight: 44)
                }.phoneGlass(theme)
                Spacer()
            }
            Text(snapshot.name).font(.largeTitle.bold())
            HStack(spacing: 10) {
                Text(model.location(snapshot)).foregroundStyle(theme.muted)
                if snapshot.dirty { Label("Unsaved", systemImage: "circle.fill").foregroundStyle(theme.signal) }
            }.font(.subheadline)
        }
    }
    private func scenes(_ snapshot: PresetSnapshot) -> some View {
        let active = Array("ABCDEFGH").firstIndex(of: snapshot.scene.first ?? "A") ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(model.sceneColor(theme, active)).frame(width: 10, height: 10)
                Text("Scene \(snapshot.scene)" + (model.sceneName(active).isEmpty ? "" : " · \(model.sceneName(active))")).font(.headline)
            }
            HStack(spacing: 4) {
                ForEach(0..<8) { index in
                    VStack(spacing: 3) {
                        Circle().fill(model.sceneColor(theme, index)).frame(width: index == active ? 12 : 9, height: index == active ? 12 : 9)
                            .overlay(Circle().stroke(theme.daylight ? theme.ink : .clear, lineWidth: 1))
                        Text(String(Array("ABCDEFGH")[index])).font(.caption.weight(.semibold))
                    }.frame(maxWidth: .infinity).frame(height: 40)
                        .background(index == active ? theme.raised : .clear, in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(index == active ? model.sceneColor(theme, index) : .clear, lineWidth: 1.5))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Scene \(String(Array("ABCDEFGH")[index])) \(model.sceneName(index))\(index == active ? ", active" : "")")
                }
            }
        }
    }
    private func grid(_ snapshot: PresetSnapshot) -> some View {
        VStack(spacing: 5) {
            ForEach(0..<4) { r in
                Button { row = r } label: {
                    HStack(spacing: 4) {
                        ForEach(0..<8) { column in
                            if let block = snapshot.blocks.first(where: { $0.position == [r, column] }) {
                                swatch(block, height: 38)
                            } else {
                                RoundedRectangle(cornerRadius: 9).stroke(theme.line).frame(maxWidth: .infinity).frame(height: 38)
                            }
                        }
                    }.padding(3).background(row == r ? theme.raised : .clear, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(row == r ? theme.signal : .clear, lineWidth: 1.5))
                }.buttonStyle(.plain).accessibilityLabel("Row \(r + 1), \(snapshot.blocks.filter { $0.position[0] == r }.count) blocks")
            }
        }.padding(8).background(theme.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.line, lineWidth: 1))
    }
    func swatch(_ block: PresetSnapshot.Block, height: CGFloat) -> some View {
        let category = model.category(block)
        let bypass = block.scenes[model.snapshot?.scene ?? ""]?.bypass == true
        return Text(category.code).font(.system(.caption2, weight: .bold)).lineLimit(1).minimumScaleFactor(0.4).strikethrough(bypass)
            .foregroundStyle(bypass ? category.color : (category.darkInk ? Color(hex: 0x161611) : .white))
            .frame(maxWidth: .infinity).frame(height: height)
            .background(bypass ? theme.surface : category.color, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(category.color, style: StrokeStyle(lineWidth: bypass ? 1.5 : 0, dash: [4, 3])))
    }
    private func rowList(_ snapshot: PresetSnapshot) -> some View {
        let blocks = snapshot.blocks.filter { $0.position[0] == row }.sorted { $0.position[1] < $1.position[1] }
        return VStack(spacing: 0) {
            HStack { Text("Row \(row + 1)").font(.headline); Spacer(); Text("\(blocks.count) blocks · \(8 - blocks.count) empty").font(.footnote).foregroundStyle(theme.muted) }.padding(.vertical, 4)
            if blocks.isEmpty { Text("No blocks in this row").foregroundStyle(theme.muted).padding(24) }
            ForEach(blocks, id: \.id) { block in
                Button { selectedBlock = block.id } label: {
                    HStack(spacing: 12) {
                        swatch(block, height: 42).frame(width: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.name(block)).font(.headline)
                            Text(model.summary(block)).font(.footnote).foregroundStyle(theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if !model.editable(block) { Image(systemName: "lock").foregroundStyle(theme.muted) }
                        Image(systemName: "chevron.right").foregroundStyle(theme.muted)
                    }.padding(.vertical, 9).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Rectangle().fill(theme.line).frame(height: 0.5)
            }
        }
    }
    private func landscapeOverview(_ snapshot: PresetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Button { sheet = .connection } label: { Label(model.demo ? "Demo" : "Mac", systemImage: "checkmark").padding(12) }.phoneGlass(theme)
                Text(snapshot.name).font(.headline).lineLimit(1)
                if snapshot.dirty { Circle().fill(theme.signal).frame(width: 8, height: 8).accessibilityLabel("Unsaved") }
                Spacer()
                HStack(spacing: 3) {
                    ForEach(0..<8) { index in
                        let letter = String(Array("ABCDEFGH")[index])
                        VStack(spacing: 2) {
                            Circle().fill(model.sceneColor(theme, index)).frame(width: 8, height: 8)
                                .overlay(Circle().stroke(theme.daylight ? theme.ink : .clear, lineWidth: 1))
                            Text(letter).font(.caption2)
                        }.frame(width: 25, height: 36)
                            .background(snapshot.scene == letter ? theme.raised : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(snapshot.scene == letter ? model.sceneColor(theme, index) : .clear))
                            .accessibilityLabel("Scene \(letter) \(model.sceneName(index))\(snapshot.scene == letter ? ", active" : "")")
                    }
                }
                if model.editor.supports("save") {
                    Button("Save") { requestSave() }.font(.headline).padding(.horizontal, 24).frame(height: 44).background(theme.signal, in: Capsule()).foregroundStyle(theme.signalInk).disabled(model.busy || !snapshot.dirty)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 5) {
                    ForEach(0..<4) { r in
                        HStack(spacing: 4) {
                            Text("\(r + 1)").font(.caption).foregroundStyle(theme.muted).frame(width: 16)
                            ForEach(0..<8) { column in
                                if let block = snapshot.blocks.first(where: { $0.position == [r, column] }) {
                                    Button { inspectedBlock = block.id } label: { swatch(block, height: 44) }
                                        .buttonStyle(.plain)
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(inspectedBlock == block.id ? theme.signal : .clear, lineWidth: 2))
                                        .accessibilityLabel(model.name(block))
                                } else { RoundedRectangle(cornerRadius: 9).stroke(theme.line).frame(maxWidth: .infinity).frame(height: 44) }
                            }
                        }
                    }
                }.padding(8).background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
                ScrollView {
                    if let block = snapshot.blocks.first(where: { $0.id == inspectedBlock }) ?? snapshot.blocks.first {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(model.name(block)).font(.headline)
                            Text(model.summary(block)).font(.footnote).foregroundStyle(theme.muted)
                            Button("Edit block") { selectedBlock = block.id }.font(.headline).frame(minHeight: 44)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(width: 180)
            }
            if let message = model.error ?? model.notice ?? model.coordinator.outcome { Text(message).font(.footnote).foregroundStyle(theme.caution) }
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }
    private func saveBar(_ snapshot: PresetSnapshot) -> some View {
        VStack(spacing: 8) {
            if let error = model.error ?? model.notice ?? model.coordinator.outcome { Label(error, systemImage: "info.circle").font(.footnote).foregroundStyle(theme.caution) }
            if model.editor.pending != nil { Label(model.editor.pending?.operation == "save" ? "Saving…" : "Sending…", systemImage: "arrow.triangle.2.circlepath").font(.footnote) }
            if model.editor.supports("save") {
                HStack {
                    if selectedBlock != nil { Label(snapshot.dirty ? "Unsaved" : "Saved", systemImage: snapshot.dirty ? "circle.fill" : "checkmark").font(.subheadline).foregroundStyle(snapshot.dirty ? theme.signal : theme.muted); Spacer() }
                    PrimaryButton(title: selectedBlock == nil ? (model.demo ? "Save demo preset" : "Save on the QC") : "Save", theme: theme) { requestSave() }
                        .frame(maxWidth: selectedBlock == nil ? .infinity : 100)
                        .disabled(model.busy || !snapshot.dirty).opacity(model.busy || !snapshot.dirty ? 0.45 : 1)
                }
            } else { Label("Read-only connection", systemImage: "lock").font(.footnote).foregroundStyle(theme.muted) }
        }.padding(.horizontal, 16).padding(.vertical, 12).phoneGlass(theme, radius: 0)
    }
    private var connection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text(connectionTitle).font(.largeTitle.bold()).padding(.top, pad ? 72 : 32)
                    .frame(maxWidth: .infinity, alignment: pad ? .center : .leading)
                HStack {
                    connectionNode(deviceName == "iPad" ? "ipad" : "iphone", deviceName)
                    Text("Bluetooth").font(.caption).foregroundStyle(theme.muted)
                    connectionNode("laptopcomputer", "Mac")
                    Text("USB").font(.caption).foregroundStyle(theme.muted)
                    connectionNode("square.grid.3x2.fill", "QC")
                }.padding(.vertical, 16)
                if model.coordinator.phase == .awaitingApproval {
                    Text("Approve this \(deviceName) in Patchbridge on your Mac.").foregroundStyle(theme.muted)
                    if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(theme.caution) }
                    if let code = model.coordinator.approvalCode { Text(code.prefix(3) + " · " + code.suffix(3)).font(.largeTitle.bold().monospacedDigit()).frame(maxWidth: .infinity).padding(24).phoneGlass(theme) }
                    PrimaryButton(title: "I’ve approved it", theme: theme) { model.coordinator.authorize() }.disabled(model.busy)
                } else if model.coordinator.phase == .recovering {
                    ProgressView("QC disconnected · waiting for USB recovery").tint(theme.signal)
                    Text("Editing is paused. Reconnect the QC cable; uncertain edits will not be retried.").foregroundStyle(theme.muted)
                    Button("Disconnect") { model.disconnect() }
                } else if model.coordinator.phase == .connecting || model.coordinator.phase == .loading {
                    ForEach(model.coordinator.nearbyMacs.keys.sorted(), id: \.self) { id in
                        Button { model.coordinator.chooseMac(id) } label: {
                            Label(model.coordinator.nearbyMacs[id] ?? "Mac", systemImage: "laptopcomputer").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        }.phoneGlass(theme)
                    }
                    if model.coordinator.nearbyMacs.isEmpty { ProgressView(model.coordinator.phase == .loading ? "Reading the preset…" : model.coordinator.status).tint(theme.signal) }
                    Button("Cancel") { model.disconnect() }.frame(minHeight: 44)
                } else if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(theme.caution)
                    PrimaryButton(title: "Reconnect", theme: theme) { model.reconnect() }
                } else {
                    TextField("Phone name (optional)", text: $phoneName).textFieldStyle(.roundedBorder)
                    Text("Shown on your Mac. Leave blank to use iPhone.").font(.footnote).foregroundStyle(theme.muted)
                    Label("Open Patchbridge on your Mac.", systemImage: "1.circle.fill")
                    Label("Plug in the QC. Close Cortex Control.", systemImage: "2.circle.fill")
                }
                Button { sheet = .getMac } label: { Label("Get Patchbridge for Mac", systemImage: "square.and.arrow.down").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(20) }.phoneGlass(theme, radius: 20)
                if let notice = model.notice { Text(notice).foregroundStyle(theme.caution) }
                if pad { connectActions.padding(.top, 8) }
            }.padding(20)
                .frame(maxWidth: pad ? 520 : .infinity).frame(maxWidth: .infinity)
        }.safeAreaInset(edge: .bottom) {
            if !pad { connectActions.padding(20) }
        }
    }
    @ViewBuilder private var connectActions: some View {
        if model.coordinator.phase == .disconnected || model.coordinator.phase == .failed {
            VStack(spacing: 10) {
                PrimaryButton(title: "Find my Mac", theme: theme) { model.start() }
                Button("Try the demo preset") { model.loadDemo() }.font(.headline).frame(maxWidth: .infinity).padding(17).background(theme.raised, in: Capsule())
            }
        }
    }
    private var connectionTitle: String {
        switch model.coordinator.phase {
        case .awaitingApproval: return "Approve on your Mac"
        case .connecting: return model.coordinator.nearbyMacs.isEmpty ? "Finding your Mac" : "Choose your Mac"
        case .loading: return "Reading the QC"
        case .recovering: return "Waiting for your QC"
        case .failed:
            switch model.coordinator.failure {
            case .bridgeFull: return "Too many devices on your Mac"
            case .revoked: return "Disconnected on your Mac"
            case nil: return model.error?.hasPrefix("Bluetooth") == true ? "Check Bluetooth" : "Connection ended"
            }
        default: return "Patchbridge"
        }
    }
    private func connectionNode(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 10) { Image(systemName: icon).font(.title).frame(maxWidth: .infinity).frame(height: 64).phoneGlass(theme, radius: 40); Text(title).font(.subheadline).foregroundStyle(theme.muted) }
    }
    @ViewBuilder private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case .getMac:
            VStack(alignment: .leading, spacing: 24) {
                Text("Get Patchbridge for Mac").font(.largeTitle.bold())
                Text("Install Patchbridge on your Mac, then connect your Quad Cortex over USB.").foregroundStyle(theme.muted)
                Link(destination: macURL) { Label("Get the Mac app", systemImage: "arrow.up.right.square").font(.headline).frame(maxWidth: .infinity).padding(17).background(theme.signal, in: Capsule()).foregroundStyle(theme.signalInk) }
                ShareLink(item: macURL) { Label("Send to my Mac", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                Button { UIPasteboard.general.url = macURL; linkCopied = true } label: { Label(linkCopied ? "Link copied" : "Copy link", systemImage: linkCopied ? "checkmark" : "doc.on.doc").frame(minHeight: 44) }
                Text("Use AirDrop to open the link on your Mac.").font(.footnote).foregroundStyle(theme.muted)
            }
        case .connection:
            VStack(alignment: .leading, spacing: 22) {
                Text("Connection details").font(.title.bold())
                Label(model.demo ? "Demo · no QC connected" : "Connected over Bluetooth", systemImage: model.demo ? "play.circle" : "checkmark.circle")
                Text(model.demo ? "Edits and saves affect this demo only." : model.coordinator.status).foregroundStyle(theme.muted)
                Text("Available now").font(.headline)
                Label("Read preset and parameter values", systemImage: "checkmark")
                if model.editor.supports("set_parameter") { Label("Edit supported parameters", systemImage: "checkmark") }
                if model.editor.supports("save") { Label("Save the current preset", systemImage: "checkmark") }
                if !model.demo && model.coordinator.trusted {
                    LabeledContent("Trusted", value: "Until revoked on the Mac").foregroundStyle(theme.ink)
                }
                if !model.demo { ConnectionStatusSettings(model: model, theme: theme) }
                Button { self.sheet = .appearance } label: { Label("Appearance", systemImage: "circle.lefthalf.filled").frame(minHeight: 44) }
                if !model.demo { Button("Refresh from Mac") { model.coordinator.refresh() }.disabled(model.busy) }
                Button(model.demo ? "Leave demo" : "Disconnect", role: .destructive) { model.disconnect(); self.sheet = nil }.foregroundStyle(theme.danger).frame(minHeight: 44)
            }
        case .appearance:
            AppearanceSettings(theme: theme)
        }
    }
}

/// Lock Screen settings for the session. The Live Activity is iPhone-only; alerts work everywhere.
struct ConnectionStatusSettings: View {
    @ObservedObject var model: PhoneModel
    let theme: PhoneTheme
    @AppStorage(ConnectionActivityController.showKey) private var showStatus = false
    @AppStorage(ConnectionActivityController.alertKey) private var alertOnDrop = false
    @State private var alertsDenied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lock Screen").font(.footnote.weight(.semibold)).foregroundStyle(theme.muted)
            if ConnectionActivityController.supported {
                Toggle("Show connection status", isOn: $showStatus).frame(minHeight: 44)
                if showStatus && !ConnectionActivityController.systemEnabled {
                    Text("Live Activities are off for Patchbridge in Settings.").font(.footnote).foregroundStyle(theme.caution)
                }
            }
            Toggle("Alert if the connection drops", isOn: $alertOnDrop).frame(minHeight: 44)
            Text(alertsDenied ? "Notifications are off for Patchbridge in Settings." : "Only for drops you didn’t start. The status doesn’t keep Bluetooth connected.")
                .font(.footnote).foregroundStyle(alertsDenied ? theme.caution : theme.muted)
        }
        .onChange(of: showStatus) { _, _ in model.connectionStatusPreferenceChanged() }
        .onChange(of: alertOnDrop) { _, on in
            guard on else { alertsDenied = false; return }
            ConnectionActivityController.requestAlertPermission { granted in alertsDenied = !granted }
        }
    }
}
