import SwiftUI
import UIKit

/// Opens the Mac app's App Store page.
let macAppURL = URL(string: "https://patchbridge.arjunakankipati.com/appstorelink")!

/// The bundled demo preset. The welcome screen and theme previews draw it before anything is connected.
struct DemoFixture: Decodable {
    let catalog: EditorCatalog
    let snapshot: PresetSnapshot
    static func load() throws -> DemoFixture {
        guard let url = Bundle.main.url(forResource: "demo-preset", withExtension: "json") else { throw EditorFailure.invalidState }
        return try JSONDecoder().decode(DemoFixture.self, from: Data(contentsOf: url))
    }
    /// Keeps the catalog's category name so the fill follows the current block colors.
    struct Cell { let categoryName: String; let bypassed: Bool; var category: BlockCategory { BlockCategory(categoryName) } }
    /// The demo's 4 × 8 grid in its active scene; nil is an empty slot.
    static let grid: [[Cell?]] = {
        var cells = [[Cell?]](repeating: [Cell?](repeating: nil, count: 8), count: 4)
        guard let fixture = try? load() else { return cells }
        for block in fixture.snapshot.blocks where block.position.count == 2 && (0..<4).contains(block.position[0]) && (0..<8).contains(block.position[1]) {
            cells[block.position[0]][block.position[1]] = Cell(categoryName: fixture.catalog.models[block.model_id]?.category ?? "",
                                                               bypassed: block.scenes[fixture.snapshot.scene]?.bypass == true)
        }
        return cells
    }()
    static let sceneColors: [Color] = ((try? load())?.snapshot.scene_colors ?? []).map { Color(hex: $0) }
    static let name: String = (try? load())?.snapshot.name ?? "Demo preset"
}

/// A small, non-interactive picture of the demo preset's signal chain.
struct DemoGrid: View {
    let theme: PhoneTheme
    var cell: CGFloat = 18
    var codes = true
    /// Thumbnail cells keep 1pt lines in high contrast; 2pt outlines would swallow them.
    private var tiny: Bool { cell < 12 }
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { r in
                HStack(spacing: 3) {
                    ForEach(0..<8, id: \.self) { c in
                        if let block = DemoFixture.grid[r][c] {
                            let category = block.category
                            // Bypassed blocks match the overview: dashed outline and struck-through code.
                            Text(codes ? category.code : "").font(.system(size: 9, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                                .strikethrough(block.bypassed)
                                .foregroundStyle(block.bypassed ? category.color : (category.darkInk ? Color(hex: 0x161611) : .white))
                                .frame(maxWidth: .infinity).frame(height: cell)
                                .background(block.bypassed ? theme.surface : category.color, in: RoundedRectangle(cornerRadius: cell * 0.3))
                                .overlay(RoundedRectangle(cornerRadius: cell * 0.3)
                                    .stroke(category.color, style: StrokeStyle(lineWidth: block.bypassed ? 1 : 0, dash: [3, 2])))
                                .blockOutline(theme, cornerRadius: cell * 0.3, filled: !block.bypassed && !tiny)
                        } else {
                            RoundedRectangle(cornerRadius: cell * 0.3).stroke(theme.line, lineWidth: tiny ? 1 : theme.hairline).frame(maxWidth: .infinity).frame(height: cell)
                        }
                    }
                }
            }
        }.accessibilityHidden(true)
    }
}

/// One device in the iPhone → Mac → QC chain, with what the player needs to know about it.
struct RailStep<Detail: View>: View {
    let icon: String
    let title: String
    var done = false
    /// The link leaving this step, drawn down from the node so the chain reads as one line.
    var below: RailLink.State?
    let theme: PhoneTheme
    @ViewBuilder var detail: Detail
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                node
                if let below { RailLine(state: below, theme: theme).frame(maxHeight: .infinity) }
            }.frame(width: 46).frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold))
                detail
            }.frame(minHeight: 46, alignment: .leading)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityValue(done ? "Connected" : "")
    }
    private var node: some View {
        Image(systemName: icon).font(.title3).frame(width: 46, height: 46)
            .background(theme.raised, in: Circle())
            .overlay(Circle().stroke(done ? theme.signal : theme.line, lineWidth: done ? 1.5 : theme.hairline))
            .overlay(alignment: .bottomTrailing) {
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(theme.signalInk)
                        .frame(width: 18, height: 18).background(theme.signal, in: Circle())
                        .overlay(Circle().stroke(theme.ground, lineWidth: 2)).offset(x: 3, y: 3)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The link between two rail steps, named by how the devices talk. It continues the line from the step above.
struct RailLink: View {
    enum State { case idle, searching, live }
    let label: String
    let state: State
    let theme: PhoneTheme
    var body: some View {
        HStack(spacing: 14) {
            RailLine(state: state, theme: theme).frame(width: 46, height: 30)
            Text(label).font(.caption).foregroundStyle(theme.muted)
            Spacer(minLength: 0)
        }.accessibilityHidden(true)
    }
}

/// Searching draws a moving dashed line; live is solid Signal; idle is a hairline.
struct RailLine: View {
    let state: RailLink.State
    let theme: PhoneTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            if state == .searching && !reduceMotion {
                TimelineView(.animation) { context in
                    line(geometry.size.height, phase: -CGFloat(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.6) / 0.6 * 8))
                }
            } else { line(geometry.size.height, phase: 0) }
        }.accessibilityHidden(true)
    }
    private func line(_ height: CGFloat, phase: CGFloat) -> some View {
        Path { path in path.move(to: CGPoint(x: 23, y: 0)); path.addLine(to: CGPoint(x: 23, y: height)) }
            .stroke(state == .idle ? theme.line : theme.signal,
                    style: StrokeStyle(lineWidth: 2, dash: state == .searching ? [4, 4] : [], dashPhase: phase))
    }
}

/// A plain text action in Signal, for secondary steps inside the rail.
struct RailAction: View {
    let title: String
    let theme: PhoneTheme
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) { Text(title); Image(systemName: "chevron.right").font(.caption.weight(.bold)) }
                .font(.subheadline.weight(.semibold)).foregroundStyle(theme.signal).frame(minHeight: 32).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct SecondaryButton: View {
    let title: String
    var icon: String?
    let theme: PhoneTheme
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label { Text(title) } icon: { if let icon { Image(systemName: icon) } }
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 17).contentShape(Capsule())
        }.buttonStyle(.plain).foregroundStyle(theme.ink).background(theme.raised, in: Capsule())
    }
}

/// Asked once, on the first screen: a phone that auto-locks mid-session can lose its Bluetooth
/// link while it waits for the QC. The same choice lives in Connection afterwards.
struct KeepAwakePrompt: View {
    let theme: PhoneTheme
    @AppStorage(PhoneModel.keepAwakeKey) private var keepAwake = false
    @AppStorage(PhoneModel.keepAwakeAskedKey) private var asked = false
    var body: some View {
        if !asked {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sun.max").font(.title3).foregroundStyle(theme.signal).frame(width: 28).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keep the screen on while connected?").font(.headline)
                        Text("If your \(deviceName) locks while it waits for the QC, the connection can drop. Uses more battery. You can change this later in Connection.")
                            .font(.footnote).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 10) {
                    Button { choose(true) } label: {
                        Text("Keep it on").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(minHeight: 44)
                            .foregroundStyle(theme.signalInk).background(theme.signal, in: Capsule())
                    }
                    Button { choose(false) } label: {
                        Text("Not now").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(minHeight: 44)
                            .foregroundStyle(theme.ink).background(theme.raised, in: Capsule())
                    }
                }.buttonStyle(.plain)
            }
            .padding(16).background(theme.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.line, lineWidth: theme.hairline))
            .transition(.opacity)
        }
    }
    private func choose(_ on: Bool) { keepAwake = on; withAnimation(.easeOut(duration: 0.2)) { asked = true } }
}

/// Gets the Mac app's link onto the Mac: an iPhone can't install it. Sharing turns the sheet into the next steps.
struct GetMacSheet: View {
    let theme: PhoneTheme
    let url: URL
    let findMac: () -> Void
    @State private var sent = false
    @State private var sharing = false
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group { if sent { sentView } else { sendView } }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: sent)
            .background(ShareSheetPresenter(isPresented: $sharing, url: url) { completed in if completed { sent = true } }.frame(width: 1, height: 1))
    }
    private var sendView: some View {
        VStack(alignment: .leading, spacing: 22) {
            handoff.padding(.top, 4)
            VStack(alignment: .leading, spacing: 8) {
                Text("Get Patchbridge for Mac").font(.largeTitle.bold())
                Text("It installs on your Mac, not this \(deviceName).").foregroundStyle(theme.muted)
            }
            VStack(spacing: 10) {
                Button { share() } label: {
                    Label("Send to my Mac", systemImage: "square.and.arrow.up").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 17).contentShape(Capsule())
                }.buttonStyle(.plain).foregroundStyle(theme.signalInk).background(theme.signal, in: Capsule())
                SecondaryButton(title: copied ? "Link copied" : "Copy link", icon: copied ? "checkmark" : "doc.on.doc", theme: theme) {
                    UIPasteboard.general.url = url; copied = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text("Or type on your Mac").font(.footnote).foregroundStyle(theme.muted)
                Text((url.host ?? "") + url.path).font(.headline).lineLimit(2).minimumScaleFactor(0.8).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.line, lineWidth: theme.hairline))
        }.transition(.opacity)
    }
    private var sentView: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark").font(.system(size: 30, weight: .bold)).foregroundStyle(theme.signalInk)
                .frame(width: 72, height: 72).background(theme.signal, in: Circle()).accessibilityHidden(true)
            Text("Link sent to your Mac").font(.title.bold()).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                numbered(1, "Install Patchbridge on your Mac.")
                numbered(2, "Open it and plug in the QC.")
            }.frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                PrimaryButton(title: "Find my Mac", theme: theme, action: findMac)
                SecondaryButton(title: "Send the link again", theme: theme) { share() }
            }
        }.transition(.opacity)
    }
    private func numbered(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 14) {
            Text("\(number)").font(.subheadline.bold()).frame(width: 30, height: 30).background(theme.raised, in: Circle()).accessibilityHidden(true)
            Text(text)
        }
    }
    /// iPhone → Mac, with a Signal dot carrying the link across.
    private var handoff: some View {
        HStack(spacing: 12) {
            node(deviceName == "iPad" ? "ipad" : "iphone")
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Path { path in path.move(to: CGPoint(x: 0, y: 4)); path.addLine(to: CGPoint(x: width, y: 4)) }
                        .stroke(theme.line, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 5]))
                    if reduceMotion {
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(theme.signal).offset(x: width - 8, y: -2)
                    } else {
                        TimelineView(.animation) { context in
                            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                            let eased = 1 - pow(1 - t, 4)
                            Circle().fill(theme.signal).frame(width: 9, height: 9)
                                .offset(x: eased * (width - 9), y: -0.5)
                                .opacity(t < 0.1 ? t * 10 : (t > 0.85 ? (1 - t) / 0.15 : 1))
                        }
                    }
                }
            }.frame(height: 9)
            node("laptopcomputer").overlay(alignment: .bottomTrailing) {
                PatchCableMark().foregroundStyle(theme.signalInk).frame(width: 17, height: 14)
                    .frame(width: 28, height: 28).background(theme.signal, in: Circle())
                    .overlay(Circle().stroke(theme.ground, lineWidth: 2.5)).offset(x: 4, y: 4)
            }
        }.padding(.horizontal, 8).accessibilityHidden(true)
    }
    private func node(_ icon: String) -> some View {
        Image(systemName: icon).font(.title2).frame(width: 60, height: 60)
            .background(theme.raised, in: Circle()).overlay(Circle().stroke(theme.line, lineWidth: theme.hairline))
    }
    private func share() { sharing = true }
}

/// UIKit's share sheet, because ShareLink doesn't say whether the link went anywhere.
/// It presents from its own host controller, so it works inside SwiftUI sheets and popovers.
struct ShareSheetPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let url: URL
    let completion: (Bool) -> Void
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ host: UIViewController, context: Context) {
        guard isPresented, host.presentedViewController == nil else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            isPresented = false
            completion(completed)
        }
        controller.popoverPresentationController?.sourceView = host.view
        controller.popoverPresentationController?.sourceRect = host.view.bounds
        DispatchQueue.main.async { host.present(controller, animated: true) }
    }
}

/// What the demo is missing, and the way out of it toward a real QC.
struct DemoExit: View {
    let theme: PhoneTheme
    let getMac: () -> Void
    let connect: () -> Void
    let leave: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                RailStep(icon: deviceName == "iPad" ? "ipad" : "iphone", title: "This \(deviceName)", done: true, below: .idle, theme: theme) {
                    Text("Running the demo preset").font(.footnote).foregroundStyle(theme.muted)
                }
                RailLink(label: "Bluetooth", state: .idle, theme: theme)
                RailStep(icon: "laptopcomputer", title: "Patchbridge on your Mac", below: .idle, theme: theme) {
                    RailAction(title: "Get the Mac app", theme: theme, action: getMac)
                }
                RailLink(label: "USB", state: .idle, theme: theme)
                RailStep(icon: "square.grid.3x2.fill", title: "Your Quad Cortex", theme: theme) {
                    Text("Edits and saves stay in this demo.").font(.footnote).foregroundStyle(theme.muted)
                }
            }
            VStack(spacing: 10) {
                PrimaryButton(title: "Connect my QC", theme: theme, action: connect)
                SecondaryButton(title: "Leave demo", theme: theme, action: leave)
            }
        }
    }
}
