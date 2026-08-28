import SwiftUI

// The notch's whole outline as a liquid surface. Every point along the left side, the bottom
// and the right side is a little spring, pushed outward when the pointer comes near it and
// coupled to its neighbours so a push in one place travels along the edge as a wave.
//
// Two earlier attempts and what they taught: a droplet on a neck read as a circle being
// dragged, because the thing that moved was never as wide as the thing it came from. Sagging
// only the bottom edge fixed that but left the sides dead, so approaching from the left did
// nothing until the pointer was underneath.
//
// Modelling the perimeter rather than a chosen edge means nothing has to decide WHICH edge is
// reacting. Corners stop being a special case: they are simply samples whose normals point
// diagonally.

/// Tunables, kept in one place so the preview can put sliders on them.
struct MagnetTuning: Equatable {
    var reach: CGFloat = 93       // how far away the pull starts being felt
    var sag: CGFloat = 12         // furthest the surface travels at full pull
    var spread: CGFloat = 80      // how localised the bulge is, in points
    var tension: CGFloat = 405    // how strongly neighbours drag each other along
    var stiffness: CGFloat = 97   // spring back to flat
    var damping: CGFloat = 33     // higher is more viscous, lower wobbles longer
    var facing: CGFloat = 1.0     // how strictly a point must face the pointer to feel it
    var openSpring: CGFloat = 130 // how eagerly it flows out into the panel
    var openDamping: CGFloat = 14 // low overshoots and settles; high arrives flat
    var lag: CGFloat = 0.16       // how far the surface trails the growth, i.e. how viscous
}

/// One sample of the outline: where it sits at rest, which way is out, and how free it is to
/// move. Points near the screen edge are pinned, so the bar never peels off the top.
private struct Rib {
    var base: CGPoint
    var normal: CGVector
    var freedom: CGFloat
}

/// Frame-to-frame state. A reference type on purpose: it is integrated inside the Canvas draw
/// closure, and mutating SwiftUI state from there would invalidate the view every frame and
/// fight the timeline already driving it.
final class LiquidSim {
    var disp: [CGFloat] = []
    var vel: [CGFloat] = []
    var last: Double = 0
    var built = CGSize.zero
    var open: CGFloat = 0       // 0 notch, 1 panel
    var openVel: CGFloat = 0
}

struct MagnetField: View {
    var notchSize: CGSize
    var pointer: CGPoint?
    /// On the real notch the window is click-through, so there is no hover to listen to.
    /// Sampling the cursor inside the draw closure instead keeps it at display rate without
    /// a timer, and without pushing SwiftUI state every frame.
    var livePointer: (() -> CGPoint?)? = nil
    var tuning = MagnetTuning()
    var showGuides = false
    /// 0 is the notch, 1 is the full panel. Driven as a spring inside the simulation rather
    /// than by SwiftUI, so it can overshoot and settle like the rest of the surface. A Canvas
    /// cannot be interpolated by an animation modifier anyway; it just redraws.
    var open: CGFloat = 0
    var panelSize: CGSize = .zero

    @State private var sim = LiquidSim()

    private static let count = 150

    /// Walk the outline once: down the left side, round the bottom, up the right.
    private func ribs(in size: CGSize, barW: CGFloat, barH: CGFloat, r: CGFloat) -> [Rib] {
        let left = (size.width - barW) / 2
        let straight = barH - r
        let arc = CGFloat.pi / 2 * r
        let flat = barW - 2 * r
        let total = straight * 2 + arc * 2 + flat

        var out: [Rib] = []
        out.reserveCapacity(Self.count)
        for i in 0..<Self.count {
            let s = total * CGFloat(i) / CGFloat(Self.count - 1)
            var p = CGPoint.zero
            var n = CGVector(dx: 0, dy: 1)
            if s < straight {                                   // left side, going down
                p = CGPoint(x: left, y: s)
                n = CGVector(dx: -1, dy: 0)
            } else if s < straight + arc {                      // bottom-left corner
                let t = (s - straight) / arc                    // 0 → 1 across the quarter turn
                let a = CGFloat.pi - t * (CGFloat.pi / 2)      // 180° → 90°, y grows downward
                let c = CGPoint(x: left + r, y: straight)
                p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                n = CGVector(dx: cos(a), dy: sin(a))
            } else if s < straight + arc + flat {                // bottom
                p = CGPoint(x: left + r + (s - straight - arc), y: barH)
                n = CGVector(dx: 0, dy: 1)
            } else if s < straight + arc * 2 + flat {            // bottom-right corner
                let t = (s - straight - arc - flat) / arc
                let a = CGFloat.pi / 2 - t * (CGFloat.pi / 2)  // 90° → 0°
                let c = CGPoint(x: left + barW - r, y: straight)
                p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                n = CGVector(dx: cos(a), dy: sin(a))
            } else {                                             // right side, going up
                // The corner arc ended level with `straight`, not with the bottom, so this
                // segment climbs from there rather than from barH.
                let up = s - (straight + arc * 2 + flat)
                p = CGPoint(x: left + barW, y: straight - up)
                n = CGVector(dx: 1, dy: 0)
            }
            // Pin the ends: they meet the top of the screen and must not move.
            let fromTop = min(p.y, barH)
            let freedom = min(1, max(0, fromTop / max(barH * 0.55, 1)))
            out.append(Rib(base: p, normal: n, freedom: freedom))
        }
        return out
    }

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let now0 = tl.date.timeIntervalSinceReferenceDate
                let dt0 = CGFloat(sim.last == 0 ? 1.0 / 60 : min(now0 - sim.last, 1.0 / 30))

                // The morph is a spring like everything else, so it arrives with a little
                // overshoot instead of stopping dead on the target size.
                let oa = tuning.openSpring * (open - sim.open) - tuning.openDamping * sim.openVel
                sim.openVel += oa * dt0
                sim.open += sim.openVel * dt0
                let o = max(0, min(1.25, sim.open))          // allow a touch past 1 to overshoot

                let target = panelSize == .zero ? notchSize : panelSize
                let barW = notchSize.width + (target.width - notchSize.width) * o
                let barH = notchSize.height + (target.height - notchSize.height) * o
                let corner = 12 + (26 - 12) * min(o, 1)

                let ribs = self.ribs(in: size, barW: barW, barH: barH, r: corner)
                if sim.disp.count != ribs.count || sim.built != size {
                    sim.disp = Array(repeating: 0, count: ribs.count)
                    sim.vel = Array(repeating: 0, count: ribs.count)
                    sim.built = size
                }

                let dt = dt0
                sim.last = now0

                let mouth = CGPoint(x: size.width / 2, y: barH)
                let sigma = max(tuning.spread, 4)
                let cursor = livePointer?() ?? pointer

                // Each rib is pulled toward the pointer by how near the pointer is TO IT, so
                // nothing has to choose an edge: whichever side you approach is the side that
                // reacts, and a corner reacts to both.
                for i in ribs.indices {
                    var target: CGFloat = 0
                    if let p = cursor {
                        let vx = p.x - ribs[i].base.x, vy = p.y - ribs[i].base.y
                        let d = hypot(vx, vy)
                        if d < tuning.reach, d > 0.001 {
                            let pull = 1 - d / tuning.reach
                            let eased = pull * pull * (3 - 2 * pull)   // smoothstep: no lurch at the rim
                            // A surface is only pulled by what is in FRONT of it. Without this
                            // every rib within reach fires on distance alone, so at a corner the
                            // whole fan of normals goes at once and it balloons, and a point can
                            // even be tugged by a pointer sitting behind the bar.
                            let dot = (vx / d) * ribs[i].normal.dx + (vy / d) * ribs[i].normal.dy
                            let front = pow(max(0, dot), tuning.facing)
                            target = tuning.sag * eased * front
                                   * exp(-(d * d) / (2 * sigma * sigma))
                        }
                    }
                    target *= ribs[i].freedom * max(0, 1 - o)

                    // While it grows, the surface trails the outline: the faster it expands,
                    // the further behind the skin lags. This is what separates flowing out
                    // from a rectangle simply getting bigger.
                    let trailing = -sim.openVel * tuning.lag * ribs[i].freedom
                    target += trailing

                    // Neighbour coupling is what makes it a surface rather than a row of
                    // independent pins: a push here lifts the points either side of it.
                    let prev = sim.disp[max(i - 1, 0)]
                    let next = sim.disp[min(i + 1, ribs.count - 1)]
                    let pullToNeighbours = tuning.tension * ((prev + next) / 2 - sim.disp[i])

                    let a = tuning.stiffness * (target - sim.disp[i])
                          + pullToNeighbours
                          - tuning.damping * sim.vel[i]
                    sim.vel[i] += a * dt
                    sim.disp[i] += sim.vel[i] * dt
                }

                var path = Path()
                path.move(to: CGPoint(x: ribs[0].base.x, y: 0))
                for i in ribs.indices {
                    let d = sim.disp[i]
                    path.addLine(to: CGPoint(x: ribs[i].base.x + ribs[i].normal.dx * d,
                                             y: ribs[i].base.y + ribs[i].normal.dy * d))
                }
                path.addLine(to: CGPoint(x: ribs[ribs.count - 1].base.x, y: 0))
                path.closeSubpath()
                ctx.fill(path, with: .color(.black))

                if showGuides {
                    var ring = Path()
                    ring.addEllipse(in: CGRect(x: mouth.x - tuning.reach, y: mouth.y - tuning.reach,
                                               width: tuning.reach * 2, height: tuning.reach * 2))
                    ctx.stroke(ring, with: .color(.white.opacity(0.10)), lineWidth: 1)
                    _ = barW
                }
            }
        }
        .allowsHitTesting(false)
    }
}
