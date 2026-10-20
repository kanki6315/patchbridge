import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct PatchbridgeWidgets: WidgetBundle {
    var body: some Widget { ConnectionActivityWidget() }
}

struct ConnectionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ConnectionAttributes.self) { context in
            let palette = ActivityPalette(daylight: context.state.daylight)
            LockScreenActivity(state: context.state, palette: palette)
                .activityBackgroundTint(palette.background)
                .activitySystemActionForegroundColor(palette.ink)
                .widgetURL(ActivityLinks.app)
        } dynamicIsland: { context in
            // The island is always black, so it always uses Stage colors.
            let palette = ActivityPalette(daylight: false)
            let look = ActivityLook(context.state, palette)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        StatusGlyph(glyph: look.glyph, color: look.tone, badgeBackground: .black, size: 18)
                        Text(context.state.macName).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.ink).lineLimit(1)
                    }.padding(.leading, 6).padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandTrail(state: context.state, look: look, palette: palette, expanded: true).padding(.trailing, 6).padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(look.islandTitle).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                            HStack(spacing: 6) {
                                if look.islandSubDot { Circle().fill(palette.signal).frame(width: 7, height: 7) }
                                look.islandSubtitle.foregroundStyle(palette.muted)
                            }.font(.system(size: 13)).monospacedDigit()
                        }
                        HStack(alignment: .bottom, spacing: 16) {
                            ConnectionRail(rail: look.rail, palette: palette, macName: context.state.macName)
                            ActivityButton(status: context.state.status, palette: palette)
                        }
                    }.foregroundStyle(palette.ink).padding(.horizontal, 6).padding(.bottom, 4)
                }
            } compactLeading: {
                StatusGlyph(glyph: look.glyph, color: look.tone, badgeBackground: .black, size: 18)
                    .accessibilityLabel("Patchbridge: \(look.title)")
            } compactTrailing: {
                IslandTrail(state: context.state, look: look, palette: palette, expanded: false)
            } minimal: {
                StatusGlyph(glyph: look.glyph, color: look.tone, badgeBackground: .black, size: 16)
                    .accessibilityLabel("Patchbridge: \(look.title)")
            }
            .keylineTint(look.tone)
            .widgetURL(ActivityLinks.app)
        }
    }
}

enum ActivityLinks {
    static let app = URL(string: "patchbridge://connection")!
}

private extension Color {
    init(rgb: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: opacity)
    }
}

/// The app's Stage and Daylight colors, as drawn in docs/design/live.
struct ActivityPalette {
    let daylight: Bool
    var background: Color { daylight ? Color(rgb: 0xfafaf8, opacity: 0.9) : Color(rgb: 0x0d0e0a, opacity: 0.88) }
    var tile: Color { Color(rgb: daylight ? 0xe9e9e5 : 0x2a2a25) }
    var ink: Color { Color(rgb: daylight ? 0x161611 : 0xf2f2ee) }
    var muted: Color { Color(rgb: daylight ? 0x555650 : 0xb1b2ab) }
    var fill: Color { daylight ? Color(rgb: 0x161611, opacity: 0.07) : Color.white.opacity(0.12) }
    var hairlineStrong: Color { daylight ? Color(rgb: 0x161611, opacity: 0.34) : Color.white.opacity(0.32) }
    var signal: Color { Color(rgb: daylight ? 0x5c6400 : 0xd1e14a) }
    var signalInk: Color { daylight ? .white : Color(rgb: 0x161802) }
    var caution: Color { Color(rgb: daylight ? 0x9d5300 : 0xffc469) }
    var danger: Color { Color(rgb: daylight ? 0xba2c25 : 0xff9683) }
    func scene(_ state: ConnectionAttributes.ContentState) -> Color { state.sceneColor.map { Color(rgb: $0) } ?? muted }
}

enum Glyph { case filled, outline, dot, warn }
/// Rail node and link states. Line style carries state, like the Mac window.
enum NodeState { case ok, wait, ask, off }
enum LinkState { case live, seek, down, none }
struct Rail { let phone: NodeState, bluetooth: LinkState, mac: NodeState, usb: LinkState, qc: NodeState }

/// Copy, tone and rail for one status.
struct ActivityLook {
    let title: String
    let glyph: Glyph
    let tone: Color
    let rail: Rail
    let islandTitle: String
    let islandSubtitle: Text
    let islandSubDot: Bool
    init(_ state: ConnectionAttributes.ContentState, _ palette: ActivityPalette) {
        let mac = state.macName
        switch state.status {
        case .connected:
            title = "Connected to \(mac)"; glyph = .filled; tone = palette.signal
            rail = Rail(phone: .ok, bluetooth: .live, mac: .ok, usb: .live, qc: .ok)
            islandTitle = state.preset ?? "Connected"
            islandSubtitle = Text(state.unsaved ? "Unsaved edits" : "No unsaved edits"); islandSubDot = state.unsaved
        case .qcLost:
            title = "Waiting for the QC"; glyph = .warn; tone = palette.caution
            rail = Rail(phone: .ok, bluetooth: .live, mac: .ok, usb: .down, qc: .wait)
            islandTitle = title; islandSubtitle = Text("Reconnect the QC’s USB cable"); islandSubDot = false
        case .lost:
            title = "Connection lost"; glyph = .warn; tone = palette.caution
            rail = Rail(phone: .ok, bluetooth: .down, mac: .wait, usb: .none, qc: .wait)
            islandTitle = title
            islandSubtitle = state.lostAt.map { Text("At \($0, style: .time)") } ?? Text("Editing is paused")
            islandSubDot = false
        case .reconnecting:
            title = "Reconnecting to \(mac)…"; glyph = .outline; tone = palette.ink
            rail = Rail(phone: .ok, bluetooth: .seek, mac: .wait, usb: .none, qc: .wait)
            islandTitle = "Reconnecting…"; islandSubtitle = Text(state.trusted ? "Trusted · no code needed" : "Finding \(mac)"); islandSubDot = false
        case .approval:
            title = "Approval needed"; glyph = .dot; tone = palette.signal
            rail = Rail(phone: .ask, bluetooth: .seek, mac: .ok, usb: .live, qc: .ok)
            islandTitle = title; islandSubtitle = Text("Approve on \(mac)"); islandSubDot = false
        case .ended:
            title = "Disconnected from \(mac)"; glyph = .outline; tone = palette.muted
            rail = Rail(phone: .ok, bluetooth: .none, mac: .off, usb: .none, qc: .off)
            islandTitle = "Disconnected"; islandSubtitle = Text(state.unsaved ? "Unsaved edits on the QC" : "No unsaved edits"); islandSubDot = state.unsaved
        }
    }
}

struct LockScreenActivity: View {
    let state: ConnectionAttributes.ContentState
    let palette: ActivityPalette
    var body: some View {
        let look = ActivityLook(state, palette)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                StatusGlyph(glyph: look.glyph, color: look.tone, badgeBackground: palette.tile, size: 20)
                    .frame(width: 40, height: 40).background(palette.tile, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(look.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    subtitle
                }
            }
            HStack(alignment: .bottom, spacing: 16) {
                ConnectionRail(rail: look.rail, palette: palette, macName: state.macName)
                ActivityButton(status: state.status, palette: palette)
            }
        }
        .foregroundStyle(palette.ink)
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Patchbridge: \(look.title)")
    }
    @ViewBuilder private var subtitle: some View {
        HStack(spacing: 6) {
            switch state.status {
            case .connected:
                if let preset = state.preset { Text(preset).fontWeight(.medium).foregroundStyle(palette.ink); separator }
                if let scene = state.scene { dot(palette.scene(state)); Text(scene); separator }
                if state.unsaved { dot(palette.signal); Text("Unsaved") } else { Text("Saved") }
            case .qcLost:
                Text(state.macName).fontWeight(.medium).foregroundStyle(palette.ink); separator; Text("USB disconnected").foregroundStyle(palette.caution)
            case .lost:
                Text(state.macName).fontWeight(.medium).foregroundStyle(palette.ink)
                if let lostAt = state.lostAt { separator; Text(lostAt, style: .time) }
            case .reconnecting:
                Text(state.macName).fontWeight(.medium).foregroundStyle(palette.ink)
                if state.trusted { separator; Text("trusted") }
            case .approval:
                Text(state.macName).fontWeight(.medium).foregroundStyle(palette.ink)
            case .ended:
                if state.unsaved { dot(palette.signal); Text("Unsaved edits on the QC") } else { Text("No unsaved edits") }
            }
        }
        .font(.system(size: 13)).monospacedDigit().foregroundStyle(palette.muted).lineLimit(1)
    }
    private var separator: some View { Text("·").foregroundStyle(palette.muted).accessibilityHidden(true) }
    private func dot(_ color: Color) -> some View { Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true) }
}

/// The QC grid, with a dot for "needs you" and a small triangle for "needs attention".
struct StatusGlyph: View {
    let glyph: Glyph
    let color: Color
    let badgeBackground: Color
    let size: CGFloat
    var body: some View {
        Image(systemName: glyph == .filled || glyph == .dot ? "square.grid.3x2.fill" : "square.grid.3x2")
            .font(.system(size: size * 0.82, weight: .semibold))
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if glyph == .dot {
                    Circle().fill(color).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(badgeBackground, lineWidth: 1.5)).offset(x: 4, y: -3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if glyph == .warn {
                    Triangle().fill(color).frame(width: size * 0.55, height: size * 0.5)
                        .overlay(Triangle().stroke(badgeBackground, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round)))
                        .offset(x: 6, y: 4)
                }
            }
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.closeSubpath()
        }
    }
}

/// iPhone, Bluetooth, Mac, USB, QC.
struct ConnectionRail: View {
    let rail: Rail
    let palette: ActivityPalette
    let macName: String
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            node("iphone", "iPhone", rail.phone)
            link(rail.bluetooth)
            node("laptopcomputer", "Mac", rail.mac)
            link(rail.usb)
            node("square.grid.3x2.fill", "QC", rail.qc)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("iPhone \(word(rail.phone)), Bluetooth \(word(rail.bluetooth)), \(macName) \(word(rail.mac)), USB \(word(rail.usb)), Quad Cortex \(word(rail.qc))")
    }
    private func node(_ symbol: String, _ label: String, _ state: NodeState) -> some View {
        let waiting = state == .wait || state == .off
        return VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(waiting ? Color.clear : palette.fill))
                .overlay(Circle().strokeBorder(palette.hairlineStrong, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5])).opacity(waiting ? 1 : 0))
                .overlay(Circle().stroke(palette.signal, lineWidth: 2).padding(-1).opacity(state == .ask ? 1 : 0))
                .foregroundStyle(waiting ? palette.muted : palette.ink)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(waiting ? palette.muted : palette.ink).lineLimit(1)
        }.frame(width: 40)
    }
    private func link(_ state: LinkState) -> some View {
        let color: Color, dash: [CGFloat]
        switch state {
        case .live: color = palette.ink.opacity(0.55); dash = []
        case .seek: color = palette.signal; dash = [4, 3]
        case .down: color = palette.caution; dash = [4, 3]
        case .none: color = palette.hairlineStrong; dash = [0.5, 3.5]
        }
        return HLine().stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: state == .none ? .round : .butt, dash: dash))
            .frame(minWidth: 8, maxWidth: .infinity).frame(height: 28)
    }
    private func word(_ state: NodeState) -> String {
        switch state { case .ok: "connected"; case .wait: "unknown"; case .ask: "waiting for approval"; case .off: "not connected" }
    }
    private func word(_ state: LinkState) -> String {
        switch state { case .live: "connected"; case .seek: "reconnecting"; case .down: "lost"; case .none: "off" }
    }
}

struct HLine: Shape {
    func path(in rect: CGRect) -> Path { Path { p in p.move(to: CGPoint(x: rect.minX, y: rect.midY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) } }
}

/// At most one button per state.
struct ActivityButton: View {
    let status: ConnectionAttributes.ContentState.Status
    let palette: ActivityPalette
    var body: some View {
        switch status {
        case .connected, .qcLost:
            Button(intent: DisconnectSessionIntent()) { capsule(Text("Disconnect"), background: palette.fill, ink: palette.danger) }
                .buttonStyle(.plain)
        case .lost:
            Button(intent: ReconnectSessionIntent()) {
                capsule(Label("Reconnect", systemImage: "arrow.clockwise"), background: palette.signal, ink: palette.signalInk)
            }.buttonStyle(.plain)
        case .reconnecting:
            capsule(HStack(spacing: 7) {
                Circle().trim(from: 0, to: 0.75).stroke(palette.muted, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .frame(width: 13, height: 13).rotationEffect(.degrees(-90)).accessibilityHidden(true)
                Text("Reconnecting")
            }, background: palette.fill, ink: palette.muted)
            .accessibilityAddTraits(.isStaticText)
        case .approval:
            Link(destination: ActivityLinks.app) { capsule(Text("Open Patchbridge"), background: palette.signal, ink: palette.signalInk) }
        case .ended:
            EmptyView()
        }
    }
    private func capsule(_ content: some View, background: Color, ink: Color) -> some View {
        content.font(.system(size: 15, weight: .semibold)).lineLimit(1).fixedSize()
            .padding(.horizontal, 18).frame(height: 44)
            .foregroundStyle(ink).background(background, in: Capsule())
    }
}

/// Compact: the scene letter or a one-word status. Expanded adds the scene name.
struct IslandTrail: View {
    let state: ConnectionAttributes.ContentState
    let look: ActivityLook
    let palette: ActivityPalette
    let expanded: Bool
    var body: some View {
        HStack(spacing: 6) {
            switch state.status {
            case .connected:
                if let scene = state.scene {
                    Circle().fill(palette.scene(state)).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(expanded ? [scene, state.sceneName?.uppercased()].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") : scene)
                        .foregroundStyle(palette.ink).accessibilityLabel("Scene \(scene)")
                }
            case .qcLost: Text("QC").foregroundStyle(palette.caution)
            case .lost: Text("Lost").foregroundStyle(palette.caution)
            case .reconnecting:
                Circle().trim(from: 0, to: 0.75).stroke(palette.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 12, height: 12).rotationEffect(.degrees(-90)).accessibilityLabel("Reconnecting")
            case .approval: Text(expanded ? "Waiting" : "Approve").foregroundStyle(palette.signal)
            case .ended: Text("Off").foregroundStyle(palette.muted)
            }
        }
        .font(.system(size: 14, weight: .semibold)).monospacedDigit().lineLimit(1)
    }
}
