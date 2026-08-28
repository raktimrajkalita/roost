import AppKit
import SwiftUI

/// The liquid notch, on the real notch.
///
/// A separate window from the panel on purpose. The panel is sized to its contents, moves,
/// and takes key focus; this one never moves, never takes focus, and must not intercept a
/// single click, since it sits over the menu bar where people are trying to press things.
final class MagnetController {
    private var window: NSPanel!
    private var visible = false
    private let tuning = MagnetTuning()

    /// Room for the bulge around the notch. The pull is felt from much further away, but the
    /// surface itself only ever travels `sag`, so the window stays small and so does the
    /// area being redrawn.
    private let pad: CGFloat = 46

    init(notchRect: CGRect, notchHeight: CGFloat) {
        let frame = CGRect(x: notchRect.midX - notchRect.width / 2 - pad,
                           y: notchRect.maxY - notchHeight - pad,
                           width: notchRect.width + pad * 2,
                           height: notchHeight + pad)
        window = NSPanel(contentRect: frame,
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver                 // above the menu bar, like the panel
        window.ignoresMouseEvents = true            // never steal a click from the menu bar
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let size = CGSize(width: notchRect.width, height: notchHeight)
        let host = NSHostingView(rootView: MagnetField(
            notchSize: size,
            pointer: nil,
            livePointer: { [weak window] in
                guard let w = window else { return nil }
                let m = NSEvent.mouseLocation                  // screen space, origin bottom-left
                return CGPoint(x: m.x - w.frame.minX,
                               y: w.frame.maxY - m.y)          // view space, origin top-left
            },
            tuning: tuning))
        window.contentView = host
    }

    /// Only on screen when it has something to say. Off screen the TimelineView stops being
    /// asked for frames, which is the whole point: this would otherwise redraw at display
    /// rate forever for a surface that is sitting perfectly still.
    func update(pointerNear: Bool, panelVisible: Bool) {
        let want = pointerNear && !panelVisible      // the panel draws its own notch strip
        guard want != visible else { return }
        visible = want
        if want { window.orderFrontRegardless() } else { window.orderOut(nil) }
    }

    /// How far out the pull is felt, so the controller knows when to bring the window back.
    var reach: CGFloat { tuning.reach }
}
