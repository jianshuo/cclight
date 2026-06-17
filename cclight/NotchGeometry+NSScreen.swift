import AppKit
import CCLightCore

extension NotchGeometry {
    /// Best-effort: read the notch dimensions from `NSScreen.safeAreaInsets`
    /// when present (macOS 12+ on notched Macs), falling back to
    /// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (the lateral rects
    /// flanking the notch). Returns nil if the screen has no notch.
    static func notchRect(for screen: NSScreen) -> CGRect? {
        let insets = screen.safeAreaInsets
        guard insets.top > 0 else { return nil }

        let menuBarHeight = NSStatusBar.system.thickness  // ~24pt
        let notchHeight = insets.top

        // Estimate notch width from auxiliaryTopLeftArea (the rect to the LEFT of the notch).
        // If it exists, screen width - left.maxX - rightArea.width gives notch width.
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        let notchWidth: CGFloat
        if let left = left, let right = right {
            notchWidth = screen.frame.maxX - left.maxX - right.width
        } else {
            // Fallback default; M4 14" notch is ~200pt.
            notchWidth = 200
        }

        return notchRect(
            screenFrame: screen.frame,
            notchSize: CGSize(width: notchWidth, height: notchHeight),
            menuBarHeight: menuBarHeight
        )
    }

    /// Width of the ambient top bar drawn on external (non-notched) displays:
    /// ~40% of the screen width, clamped to a sane range so it neither
    /// disappears on small monitors nor sprawls across ultrawides.
    static func topBarWidth(for screen: NSScreen) -> CGFloat {
        min(max(screen.frame.width * 0.4, 240), 720)
    }

    /// A zero-height rect centered on the screen's top edge, used as the basis
    /// for the bar overlay window (expanded by `overlayWindowFrame`'s padding).
    /// Mirrors how the notch overlay sits at `screen.frame.maxY`.
    static func topBarRect(for screen: NSScreen, width: CGFloat) -> CGRect {
        CGRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY,
            width: width,
            height: 0
        )
    }
}
