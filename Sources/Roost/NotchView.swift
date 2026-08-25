import SwiftUI
import AppKit

/// Real backdrop blur (frosted glass) — samples what's behind the window.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// Observable state the SwiftUI panel renders from.
final class NotchModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var notchHeight: CGFloat = 32
    @Published var width: CGFloat = 380          // body width (rows sit here)
    @Published var expanded: Bool = false        // drives the grow-out-of-the-notch spring
    @Published var collapsedScaleX: CGFloat = 0.4    // notch width / full width  (set by controller)
    @Published var collapsedScaleY: CGFloat = 0.13   // notch height / full height (set by controller)
    @Published var searching: Bool = false       // search bar open
    @Published var query: String = ""
    var onFocus: (Session) -> Void = { _ in }
    var onMute: (String) -> Void = { _ in }
    var onDismiss: (String) -> Void = { _ in }
    var onReload: () -> Void = { }
    var onSearchWillOpen: () -> Void = { }        // grow the window + take keys BEFORE anything animates
    var onSearchDidClose: () -> Void = { }        // collapse once the bar has retracted
    var onLayout: () -> Void = { }                // re-measure the window when results change
    var searchFn: (String) -> [Session] = { _ in [] }

    /// What the list renders: search results when searching, otherwise the live panel list.
    var rows: [Session] {
        (searching && !query.trimmingCharacters(in: .whitespaces).isEmpty)
            ? searchFn(query) : sessions
    }

    let flareW: CGFloat = 20     // top shoulders flare this far past each body wall
    let flareH: CGFloat = 13     // vertical height of the concave shoulder curve
    var fullWidth: CGFloat { width + flareW * 2 }
}

/// The absolute-black panel that grows out of the notch, with rounded bottom corners.
struct NotchView: View {
    @ObservedObject var model: NotchModel
    @FocusState private var searchFocused: Bool

    /// The panel's overall state, read off the whole list rather than any one row:
    /// still working → a white breath; blocked → amber; everything finished → green;
    /// nothing running at all → a quiet blue.
    private var glow: (color: Color, breathing: Bool, peak: Double) {
        let idleBlue = Color(red: 0.48, green: 0.64, blue: 1.0)
        if model.sessions.isEmpty { return (idleBlue, false, 0.12) }
        if model.sessions.contains(where: { $0.status == "thinking" }) { return (.white, true, 0.13) }
        if model.sessions.contains(where: { $0.status == "waiting" }) { return (statusColor("waiting"), false, 0.12) }
        if model.sessions.allSatisfy({ $0.status == "done" }) { return (statusColor("done"), false, 0.12) }
        return (idleBlue, false, 0.12)
    }

    private func glowGradient(_ color: Color, peak: Double) -> some View {
        LinearGradient(stops: [
            .init(color: color.opacity(peak), location: 0.0),
            .init(color: color.opacity(peak * 0.34), location: 0.20),
            .init(color: .clear, location: 0.52)
        ], startPoint: .bottom, endPoint: .top)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Fused notch area. The controls live in HERE, not overlaid on the whole panel —
            // this strip is a fixed height that never animates, so they can't be dragged around
            // by the panel's spring when the search bar opens.
            Color.clear
                .frame(height: model.notchHeight)
                .overlay(alignment: .leading) {
                    ReloadButton(action: model.onReload)
                        .padding(.leading, 12 + model.flareW)
                }
                .overlay(alignment: .trailing) {
                    SearchToggleButton(active: model.searching) { toggleSearch() }
                        .padding(.trailing, 12 + model.flareW)
                }
            if model.searching {
                SearchBar(query: $model.query, focused: $searchFocused)
                    .padding(.horizontal, 8 + model.flareW)
                    .padding(.top, 11)
                    .padding(.bottom, 8)
                    .transition(.asymmetric(       // descends out of the notch, like the panel itself
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)))
            }
            Group {
                if model.rows.isEmpty {
                    Group {
                        if model.searching && !model.query.isEmpty {
                            Text("no session matches “\(model.query)”")
                        } else {
                            HStack(spacing: 7) {          // a word space is too tight beside the emoji
                                Text("👻")
                                Text("no active claude sessions")
                            }
                        }
                    }
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                } else if model.rows.count > 10 {
                    ScrollView(.vertical, showsIndicators: true) {   // beyond 10, cap the height and scroll
                        VStack(spacing: 3) {
                            ForEach(model.rows) { s in
                                RowView(session: s, onFocus: model.onFocus, onMute: model.onMute, onDismiss: model.onDismiss)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .top)),
                                    removal: .move(edge: .trailing).combined(with: .opacity)))
                            }
                        }
                    }
                    .frame(height: 487)                              // exactly 10 rows (10·46 + 9·3), then scroll
                } else {
                    VStack(spacing: 3) {
                        ForEach(model.rows) { s in
                            RowView(session: s, onFocus: model.onFocus, onMute: model.onMute, onDismiss: model.onDismiss)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .top)),
                                    removal: .move(edge: .trailing).combined(with: .opacity)))
                        }
                    }
                }
            }
            .padding(.horizontal, 8 + model.flareW)      // inset content to the body width, inside the flare
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .frame(width: model.fullWidth)
        .background(
            VStack(spacing: 0) {
                // notch strip: absolute, 100% opaque black — no blur behind it at all
                Color.black
                    .frame(height: model.notchHeight)
                // body: real frosted glass, black eased from solid (at the notch line) to 40% at the bottom
                ZStack {
                    VisualEffectBlur(material: .hudWindow)                 // background blur ~35% — glass, body only
                        .opacity(0.7)
                    LinearGradient(colors: [.black, .black.opacity(0.40)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .frame(maxHeight: .infinity)
            }
            // inner glow: brightest along the very bottom edge, falling off to black as it rises.
            // Its colour and motion report the state of the whole panel at a glance.
            .overlay(alignment: .bottom) {
                Group {
                    if glow.breathing {
                        TimelineView(.animation) { tl in
                            let t = tl.date.timeIntervalSinceReferenceDate
                            let p = 0.5 + 0.5 * sin(2 * Double.pi * 0.30 * t)   // ~3.3s breath
                            glowGradient(glow.color, peak: 0.055 + 0.095 * p)
                        }
                    } else {
                        glowGradient(glow.color, peak: glow.peak)
                    }
                }
                .allowsHitTesting(false)
            }
        )
        .clipShape(NotchPanelShape(flareW: model.flareW, flareH: model.flareH, bottomR: 26))
        .onChange(of: model.query) { _ in model.onLayout() }
        // grow out of the notch: collapsed = a notch-sized sliver pinned top-centre; expanded = full panel
        .scaleEffect(x: model.expanded ? 1 : model.collapsedScaleX,
                     y: model.expanded ? 1 : model.collapsedScaleY,
                     anchor: .top)
        .opacity(model.expanded ? 1 : 0)
        .animation(.spring(response: 0.36, dampingFraction: 0.80), value: model.expanded)
        // the window may be taller than the panel (it only grows while searching, never shrinks),
        // so keep the panel itself hugging the notch instead of centring in the leftover space
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func toggleSearch() {
        let opening = !model.searching
        // Resize and take key focus first, while nothing is animating — doing either mid-flight
        // forces a re-layout on top of a running animation, which is what made the panel blink.
        if opening { model.onSearchWillOpen() }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            model.searching = opening
            if !opening { model.query = "" }
        }
        if !opening { model.onSearchDidClose() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (opening ? 0.06 : 0)) {
            searchFocused = opening
        }
    }
}

/// The search field: no chrome, just a rule underneath that draws itself in from the left.
struct SearchBar: View {
    @Binding var query: String
    @FocusState.Binding var focused: Bool
    @State private var lineIn = false

    var body: some View {
        // No clear button — the ✕ up in the strip already closes search and empties the query,
        // and sitting at the same trailing edge the two read as a doubled control.
        TextField("Search any sessions", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.95))
            .focused($focused)
            .onSubmit { focused = false }
        .padding(.bottom, 7)
        // rule spans the field itself, so it starts at the lens and ends under the clear button —
        // same left/right inset as the rows below
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(focused ? 0.30 : 0.15))
                .frame(height: 1)
                .scaleEffect(x: lineIn ? 1 : 0, anchor: .leading)   // draws in left → right
        }
        .padding(.horizontal, 10)      // lines the lens up with the row indicators below
        .animation(.easeOut(duration: 0.2), value: focused)
        .onAppear {
            withAnimation(.easeOut(duration: 0.34).delay(0.04)) { lineIn = true }
        }
    }
}

/// One control that stays put and changes identity: a lens when collapsed, an ✕ while
/// searching. Nothing travels — only the bar moves.
struct SearchToggleButton: View {
    var active: Bool
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: "magnifyingglass")
                    .opacity(active ? 0 : 1)
                    .rotationEffect(.degrees(active ? -90 : 0))
                    .scaleEffect(active ? 0.55 : 1)
                Image(systemName: "xmark")
                    .opacity(active ? 1 : 0)
                    .rotationEffect(.degrees(active ? 0 : 90))
                    .scaleEffect(active ? 1 : 0.55)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(hover || active ? 0.7 : 0.28))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: active)
        .help(active ? "Close search" : "Search sessions")
    }
}

/// Muted reload control in the panel's top-right corner (beside the notch).
struct ReloadButton: View {
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(hover ? 0.7 : 0.28))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Refresh")
    }
}

struct RowView: View {
    let session: Session
    var onFocus: (Session) -> Void
    var onMute: (String) -> Void
    var onDismiss: (String) -> Void
    @State private var hover = false

    // Actionable rows sit forward, working rows sit back — carried by the whole row, not just the dot.
    private var nameOpacity: Double {
        if session.muted { return 0.5 }
        switch session.status {
        case "waiting": return 0.97
        case "done": return 0.92
        case "thinking": return 0.82
        default: return 0.78
        }
    }
    private var actionOpacity: Double {
        if session.muted { return 0.3 }
        switch session.status {
        case "waiting": return 0.50
        case "done": return 0.42
        case "thinking": return 0.36
        default: return 0.32
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            StatusIndicator(status: session.status, doneAt: session.doneAt)
                .frame(width: 18, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.white.opacity(nameOpacity))
                    .lineLimit(1)
                Text(session.lastAction.isEmpty ? session.status : session.lastAction)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(actionOpacity))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // At rest: how long it's been. On hover: the controls, in the same slot.
            // Fixed width so nothing shifts when they swap.
            Group {
                if hover {
                    HStack(spacing: 0) {
                        Button(action: { onMute(session.id) }) {
                            Image(systemName: session.muted ? "bell.slash.fill" : "bell.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(session.muted ? 0.85 : 0.55))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button(action: { onDismiss(session.id) }) {   // hide it until this session next updates
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.55))
                                .frame(width: 22, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    HStack(spacing: 4) {
                        if session.muted {                            // muted is a state worth showing at rest
                            Image(systemName: "bell.slash.fill")
                                .font(.system(size: 9.5))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        TimelineView(.periodic(from: Date(), by: 15)) { tl in
                            Text(relativeAge(session, now: tl.date))
                                .font(.system(size: 10.5))
                                .monospacedDigit()
                                .foregroundColor(.white.opacity(session.status == "thinking" ? 0.22 : 0.32))
                        }
                    }
                }
            }
            .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(.white.opacity(hover ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { onFocus(session) }
    }

}

// MARK: - status colour + math-driven indicators (one visual family)

// Two hues only. Colour means something needs you: amber = answer me, green = finished.
// Thinking has no hue at all — it's just working, so it stays white.
func statusColor(_ status: String) -> Color {
    switch status {
    case "done": return Color(red: 0.23, green: 0.82, blue: 0.5)
    case "waiting": return Color(red: 1.0, green: 0.69, blue: 0.13)
    case "thinking": return .white
    default: return .white.opacity(0.5)
    }
}

/// Relative age of a row — replaces the old status word, which only repeated the icon.
func relativeAge(_ session: Session, now: Date) -> String {
    let stamp = (session.status == "done" && session.doneAt > 0) ? session.doneAt : session.updated
    let d = max(0, now.timeIntervalSince1970 - stamp)
    if d < 60 { return "now" }
    if d < 3600 { return "\(Int(d / 60))m" }
    return "\(Int(d / 3600))h"
}

// One family, three energy levels: dispersed while working, a single pulse while
// it needs you, gathered and at rest when it's done.
struct StatusIndicator: View {
    let status: String
    var doneAt: Double = 0
    var body: some View {
        switch status {
        case "thinking":
            BloomIndicator(color: statusColor(status))
        case "waiting":
            PulseDot(color: statusColor(status))
        case "done":
            SettleIndicator(color: statusColor(status), doneAt: doneAt)
        default:
            Circle().fill(statusColor(status)).frame(width: 8, height: 8)
        }
    }
}

/// thinking — nine dots on a phyllotaxis spiral: golden angle 137.5°, radius √n,
/// each breathing on a staggered phase. Dispersed = working.
struct BloomIndicator: View {
    var color: Color
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let R = Double(min(size.width, size.height)) / 2 * 0.92
                let cx = Double(size.width) / 2, cy = Double(size.height) / 2
                let n = 9, ga = 2.399963
                let spin = 2 * Double.pi * 0.05 * t
                for i in 0..<n {
                    let a = Double(i) * ga + spin
                    let rad = R * 0.95 * (Double(i) / Double(n - 1)).squareRoot()
                    let p = 0.5 + 0.5 * sin(2 * Double.pi * 0.45 * t - Double(i) * 0.55)
                    let r = R * 0.15 * (0.65 + 0.5 * p)
                    let x = cx + cos(a) * rad, y = cy + sin(a) * rad * 0.8
                    ctx.opacity = 0.3 + 0.7 * p
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                             with: .color(color))
                }
            }
        }
    }
}

/// waiting — a single dot, pulsing. Blocked on you.
struct PulseDot: View {
    var color: Color
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let p = 0.5 + 0.5 * sin(2 * Double.pi * 0.8 * t)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .scaleEffect(0.80 + 0.28 * p)
                .opacity(0.42 + 0.58 * p)
        }
    }
}

/// done — the halo collapses inward onto a settled core, once, then holds.
/// Driven off the session's own done_at, so it resolves on arrival and never replays.
struct SettleIndicator: View {
    var color: Color
    var doneAt: Double
    var body: some View {
        TimelineView(.animation) { tl in
            let now = tl.date.timeIntervalSince1970
            let u = min(1, max(0, (now - doneAt) / 0.66))
            let e = 1 - pow(1 - u, 3)                       // easeOutCubic
            Canvas { ctx, size in
                let R = Double(min(size.width, size.height)) / 2 * 0.92
                let cx = Double(size.width) / 2, cy = Double(size.height) / 2
                let hr = R * (1.25 - 0.45 * e)              // halo, contracting
                ctx.opacity = 0.30 * (1 - e) + 0.15
                ctx.stroke(Path(ellipseIn: CGRect(x: cx - hr, y: cy - hr, width: hr * 2, height: hr * 2)),
                           with: .color(color), lineWidth: max(R * 0.13, 0.5))
                let cr = R * (0.20 + 0.28 * e)              // core, settling
                ctx.opacity = 1
                ctx.fill(Path(ellipseIn: CGRect(x: cx - cr, y: cy - cr, width: cr * 2, height: cr * 2)),
                         with: .color(color))
            }
        }
    }
}

/// The panel grows out of the notch: flat top flush with the menu bar, concave
/// "shoulders" flaring the top corners outward, vertical body walls, rounded bottom.
struct NotchPanelShape: Shape {
    var flareW: CGFloat
    var flareH: CGFloat
    var bottomR: CGFloat
    func path(in rect: CGRect) -> Path {
        let W = rect.width, H = rect.height
        let bx0 = flareW                 // left body wall
        let bx1 = W - flareW             // right body wall
        let br = min(bottomR, (bx1 - bx0) / 2, H / 2)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))                     // top-left flare tip
        p.addLine(to: CGPoint(x: W, y: 0))                  // flat top edge (flush with menu bar)
        // top-right concave shoulder: leaves the top edge horizontally, meets the wall vertically
        p.addQuadCurve(to: CGPoint(x: bx1, y: flareH), control: CGPoint(x: bx1, y: 0))
        p.addLine(to: CGPoint(x: bx1, y: H - br))           // right wall
        p.addArc(tangent1End: CGPoint(x: bx1, y: H),
                 tangent2End: CGPoint(x: bx1 - br, y: H), radius: br)     // bottom-right round
        p.addLine(to: CGPoint(x: bx0 + br, y: H))           // bottom edge
        p.addArc(tangent1End: CGPoint(x: bx0, y: H),
                 tangent2End: CGPoint(x: bx0, y: H - br), radius: br)     // bottom-left round
        p.addLine(to: CGPoint(x: bx0, y: flareH))           // left wall
        // top-left concave shoulder: leaves the wall vertically, meets the top edge horizontally
        p.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: bx0, y: 0))
        p.closeSubpath()
        return p
    }
}
