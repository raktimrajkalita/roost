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
    var onFocus: (String) -> Void = { _ in }
    var onMute: (String) -> Void = { _ in }
    var onReload: () -> Void = { }

    let flareW: CGFloat = 20     // top shoulders flare this far past each body wall
    let flareH: CGFloat = 13     // vertical height of the concave shoulder curve
    var fullWidth: CGFloat { width + flareW * 2 }
}

/// The absolute-black panel that grows out of the notch, with rounded bottom corners.
struct NotchView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchHeight)   // fused notch area (black bg shows through)
            Group {
                if model.sessions.isEmpty {
                    Text("no active claude sessions")
                        .font(.system(size: 12.5))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                } else if model.sessions.count > 10 {
                    ScrollView(.vertical, showsIndicators: true) {   // beyond 10, cap the height and scroll
                        VStack(spacing: 3) {
                            ForEach(model.sessions) { s in
                                RowView(session: s, onFocus: model.onFocus, onMute: model.onMute)
                            }
                        }
                    }
                    .frame(height: 487)                              // exactly 10 rows (10·46 + 9·3), then scroll
                } else {
                    VStack(spacing: 3) {
                        ForEach(model.sessions) { s in
                            RowView(session: s, onFocus: model.onFocus, onMute: model.onMute)
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
        )
        .clipShape(NotchPanelShape(flareW: model.flareW, flareH: model.flareH, bottomR: 26))
        .overlay(alignment: .topTrailing) {
            ReloadButton(action: model.onReload)
                .padding(.top, max((model.notchHeight - 22) / 2, 3))
                .padding(.trailing, 12 + model.flareW)     // keep it inside the flare, not out on the shoulder
        }
        // grow out of the notch: collapsed = a notch-sized sliver pinned top-centre; expanded = full panel
        .scaleEffect(x: model.expanded ? 1 : model.collapsedScaleX,
                     y: model.expanded ? 1 : model.collapsedScaleY,
                     anchor: .top)
        .opacity(model.expanded ? 1 : 0)
        .animation(.spring(response: 0.36, dampingFraction: 0.80), value: model.expanded)
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
    var onFocus: (String) -> Void
    var onMute: (String) -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 11) {
            StatusIndicator(status: session.status)
                .frame(width: 18, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.white.opacity(session.muted ? 0.5 : 0.95))
                    .lineLimit(1)
                Text(session.lastAction.isEmpty ? session.status : session.lastAction)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(session.muted ? 0.3 : 0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(session.status)
                .font(.system(size: 10))
                .foregroundColor(statusColor(session.status))
            Button(action: { onMute(session.id) }) {
                Image(systemName: session.muted ? "bell.slash.fill" : "bell.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(session.muted ? 0.8 : 0.45))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(.white.opacity(hover ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if let u = session.itermUUID { onFocus(u) } }
    }

}

// MARK: - status colour + math-driven indicators (one visual family)

func statusColor(_ status: String) -> Color {
    switch status {
    case "done": return Color(red: 0.23, green: 0.82, blue: 0.5)
    case "waiting": return Color(red: 1.0, green: 0.69, blue: 0.13)
    case "thinking": return Color(red: 0.48, green: 0.64, blue: 1.0)
    default: return .white.opacity(0.5)
    }
}

struct StatusIndicator: View {
    let status: String
    var body: some View {
        switch status {
        case "thinking":
            ThinkingIndicator(color: statusColor(status))
        case "waiting":
            BreathingDot(color: statusColor(status))
        case "done":
            Image(systemName: "checkmark")                 // static — at rest
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(statusColor(status))
        default:
            Circle().fill(statusColor(status)).frame(width: 8, height: 8)
        }
    }
}

/// thinking — three dots gently swelling in sequence (calm "thinking…").
struct ThinkingIndicator: View {
    var color: Color
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3.5) {
                ForEach(0..<3, id: \.self) { i in
                    let a = 0.5 + 0.5 * sin(2 * Double.pi * 0.75 * t - Double(i) * 0.85)  // 0…1, staggered
                    Circle()
                        .fill(color)
                        .frame(width: 4.5, height: 4.5)
                        .scaleEffect(0.72 + 0.32 * a)
                        .opacity(0.4 + 0.6 * a)
                }
            }
        }
    }
}

/// waiting — a calm breathing pulse: a solid dot with a halo that expands and fades.
struct BreathingDot: View {
    var color: Color
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let p = 0.5 + 0.5 * sin(2 * Double.pi * 0.7 * t)          // 0…1
            ZStack {
                Circle().fill(color.opacity(0.35 * (1 - p)))
                    .frame(width: CGFloat(8 + 9 * p), height: CGFloat(8 + 9 * p))
                Circle().fill(color).frame(width: 8, height: 8)
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
