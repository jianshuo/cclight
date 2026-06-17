import AppKit
import Combine
import QuartzCore
import CCLightCore

/// What outline this overlay traces. The notch wraps the built-in display's
/// notch in a U; the bar is a centered horizontal line at the top edge of an
/// external (non-notched) display. Both reuse the exact same segment/color/
/// glow/breath machinery — only the base path and segment direction differ.
enum OverlayShape {
    /// U-shape hugging the notch of the given pixel size.
    case notch(CGSize)
    /// Centered horizontal bar of the given width at the top of the screen.
    case bar(width: CGFloat)

    /// How far the overlay window is expanded beyond the outline on every side,
    /// giving the halo room to bleed before the window clips it. The bar runs a
    /// larger, more prominent glow so it needs more room than the notch.
    var glowPadding: CGFloat {
        switch self {
        case .notch: return 90
        case .bar:   return 165
        }
    }
}

/// Per PROJECT.md: a low-key thin line wrapping the notch with a subtle halo
/// glow. Extended for multi-session: the outline is split into N equal
/// segments (capped at 4 by StateStore), each colored by its session's state.
/// Also extended for multi-monitor: the same view renders a top bar on
/// external displays (see `OverlayShape`).
///
/// Implementation: N `CAShapeLayer`s all stroke the same path but each uses
/// `strokeStart` / `strokeEnd` to render only its 1/N portion. Each layer
/// owns its own colored shadow so per-segment glows don't bleed into the full
/// outline (no shared `shadowPath`).
final class NotchOverlayView: NSView {
    private let shape: OverlayShape
    private var subs: Set<AnyCancellable> = []
    /// 5 stacked layers per segment matching the variant-10 "Steady Neon"
    /// box-shadow stack: a crisp solid line + four progressively-soft glow
    /// halos at radii 6 / 14 / 28 / 50 with opacities 0.9 / 0.7 / 0.4 / 0.2.
    private struct SegmentLayers {
        let line = CAShapeLayer()    // crisp solid stroke (no shadow)
        let glow1 = CAShapeLayer()   // tight halo, r=6
        let glow2 = CAShapeLayer()   // medium halo, r=14
        let glow3 = CAShapeLayer()   // wide halo, r=28
        let glow4 = CAShapeLayer()   // soft aura, r=50
        let glow5 = CAShapeLayer()   // faint outer aura, r=80
        var all: [CAShapeLayer] { [line, glow1, glow2, glow3, glow4, glow5] }
    }
    private var segments: [SegmentLayers] = []
    private var currentStates: [MergedState] = []
    private var cachedPath: CGPath?

    /// Whether this view renders the filled tapered bar (vs the stroked notch U).
    private var isBar: Bool { if case .bar = shape { return true }; return false }

    /// Per-shape line weight and halo stack. The bar is thicker with a wider,
    /// more prominent glow than the notch. `radii`/`opacities` index glow1…glow5
    /// (tight → soft). Radii stay within `shape.glowPadding` so the window
    /// doesn't clip the outermost aura.
    private struct GlowConfig {
        let lineWidth: CGFloat
        let radii: [CGFloat]
        let opacities: [Float]
    }
    private var glow: GlowConfig {
        switch shape {
        case .notch:
            return GlowConfig(lineWidth: 3.0, radii: [6, 14, 28, 50, 80], opacities: [1.0, 1.0, 0.9, 0.7, 0.4])
        case .bar:
            return GlowConfig(lineWidth: 4.5, radii: [11, 26, 52, 92, 140], opacities: [1.0, 1.0, 1.0, 0.95, 0.72])
        }
    }

    init(shape: OverlayShape) {
        self.shape = shape
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func bindSessions<P: Publisher>(_ publisher: P) where P.Output == [MergedState], P.Failure == Never {
        publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] states in self?.apply(states: states, animated: true) }
            .store(in: &subs)
    }

    override func layout() {
        super.layout()
        rebuildPath()
        relayoutSegments()
    }

    // MARK: - Path

    private func rebuildPath() {
        switch shape {
        case .notch(let notchSize): cachedPath = notchPath(notchSize: notchSize)
        // The bar builds an independent filled path per segment in
        // relayoutSegments() (it can't share one stroked path), so there's no
        // single cached path to keep here.
        case .bar:                  cachedPath = nil
        }
    }

    /// Half-height of the bar's tapered profile at a given x. Full height `h/2`
    /// across the flat middle, easing smoothly to 0 at both ends over a taper
    /// region of length `t` — so the bar comes to a point (0 height) at each
    /// end instead of stopping square.
    private func barHalfHeight(_ x: CGFloat, x0: CGFloat, x1: CGFloat, h: CGFloat, t: CGFloat) -> CGFloat {
        guard x > x0, x < x1 else { return 0 }
        // `s` runs 0 at the inner edge of the taper to 1 at the tip.
        let s: CGFloat
        if x < x0 + t { s = (x0 + t - x) / t }
        else if x > x1 - t { s = (x - (x1 - t)) / t }
        else { return h / 2 }
        // Quarter-ellipse cap: half-height = (h/2)·√(1 − s²). The edge bulges
        // outward (tangent to the flat middle at the inner edge, vertical at the
        // tip) instead of collapsing in a straight wedge.
        return (h / 2) * sqrt(max(0, 1 - s * s))
    }

    /// Closed filled outline of the bar slice covering [xa, xb], following the
    /// tapered profile. Top edge xa→xb, bottom edge xb→xa, closed. Interior
    /// segment boundaries meet flush (full local height); the two outer ends
    /// taper to a point.
    private func barSegmentPath(xa: CGFloat, xb: CGFloat, x0: CGFloat, x1: CGFloat, yc: CGFloat, h: CGFloat, t: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let steps = max(2, Int((xb - xa) / 3))
        func x(at k: Int) -> CGFloat { xa + (xb - xa) * CGFloat(k) / CGFloat(steps) }
        for k in 0...steps {
            let px = x(at: k)
            let py = yc + barHalfHeight(px, x0: x0, x1: x1, h: h, t: t)
            if k == 0 { path.move(to: CGPoint(x: px, y: py)) }
            else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
        for k in stride(from: steps, through: 0, by: -1) {
            let px = x(at: k)
            let py = yc - barHalfHeight(px, x0: x0, x1: x1, h: h, t: t)
            path.addLine(to: CGPoint(x: px, y: py))
        }
        path.closeSubpath()
        return path
    }

    private func notchPath(notchSize: CGSize) -> CGPath {
        let b = bounds
        let cornerRadius: CGFloat = 12
        // notch centered horizontally, at the top of the view (AppDelegate
        // creates window as notchRect.insetBy(-glowPadding, -glowPadding)).
        let glowPadding = shape.glowPadding
        let notchRect = CGRect(
            x: (b.width - notchSize.width) / 2,
            y: b.height - glowPadding - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )

        // U-shape outline path: top-right → down → arc → across → arc → up → top-left.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: notchRect.maxX, y: notchRect.maxY))
        path.addLine(to: CGPoint(x: notchRect.maxX, y: notchRect.minY + cornerRadius))
        path.addArc(
            center: CGPoint(x: notchRect.maxX - cornerRadius, y: notchRect.minY + cornerRadius),
            radius: cornerRadius,
            startAngle: 0, endAngle: -.pi / 2, clockwise: true
        )
        path.addLine(to: CGPoint(x: notchRect.minX + cornerRadius, y: notchRect.minY))
        path.addArc(
            center: CGPoint(x: notchRect.minX + cornerRadius, y: notchRect.minY + cornerRadius),
            radius: cornerRadius,
            startAngle: -.pi / 2, endAngle: -.pi, clockwise: true
        )
        path.addLine(to: CGPoint(x: notchRect.minX, y: notchRect.maxY))
        return path
    }

    // MARK: - Apply

    private func apply(states: [MergedState], animated: Bool) {
        NSLog("cclight: apply states=\(states.map { $0.rawValue })")

        let effectiveCount = max(states.count, 1)
        ensureSegmentCount(effectiveCount)
        relayoutSegments()

        for i in 0..<effectiveCount {
            let segment = segments[i]
            let state: MergedState = states.isEmpty ? .idle : states[i]
            let color = Self.cgColor(for: state)
            let opacity: Float = (state == .idle) ? 0.20 : 1.0

            CATransaction.begin()
            CATransaction.setAnimationDuration(animated ? 0.35 : 0)
            for shape in segment.all {
                // Bar is a filled tapered shape; notch is a stroked outline.
                if isBar {
                    shape.fillColor = color
                } else {
                    shape.strokeColor = color
                }
                shape.shadowColor = color
                shape.opacity = opacity
            }
            CATransaction.commit()

            applyBreath(to: segment, state: state)
        }

        currentStates = states
    }

    /// Breathing halo: pulses the soft outer glow layers between 45% and 100%
    /// opacity. The crisp line stays steady so the U-shape outline remains
    /// sharp — only the aura breathes. `.working` uses a calm 1.8 s cadence;
    /// `.attention` uses a faster 1.0 s cadence to convey urgency.
    ///
    /// Idempotent: if the breath animation is already running with the same
    /// cadence we leave it alone, so apply() being called on every StateStore
    /// publish doesn't constantly reset the phase. We do reset if the cadence
    /// needs to change (working → attention or vice versa).
    private func applyBreath(to segment: SegmentLayers, state: MergedState) {
        let breathing = [segment.glow1, segment.glow2, segment.glow3, segment.glow4, segment.glow5]
        let duration: CFTimeInterval?
        switch state {
        case .working:   duration = 1.8
        case .attention: duration = 1.0
        case .waiting, .idle: duration = nil
        }
        guard let duration = duration else {
            for layer in breathing { layer.removeAnimation(forKey: "breath") }
            return
        }
        if let existing = breathing.first?.animation(forKey: "breath") as? CABasicAnimation,
           existing.duration == duration {
            return
        }
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 0.45
        breath.toValue = 1.0
        breath.duration = duration
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        for layer in breathing {
            layer.add(breath, forKey: "breath")
        }
    }

    private func ensureSegmentCount(_ count: Int) {
        let cfg = glow
        while segments.count < count {
            let s = SegmentLayers()
            // Z-order: widest soft aura at bottom, crispest line on top.
            for shape in [s.glow5, s.glow4, s.glow3, s.glow2, s.glow1, s.line] {
                shape.fillColor = NSColor.clear.cgColor
                shape.lineCap = .butt
                shape.lineJoin = .round
                shape.lineWidth = cfg.lineWidth
                shape.shadowOffset = .zero
                layer?.addSublayer(shape)
            }
            s.line.shadowOpacity = 0
            let glowLayers = [s.glow1, s.glow2, s.glow3, s.glow4, s.glow5]
            for (i, glowLayer) in glowLayers.enumerated() {
                glowLayer.shadowRadius = cfg.radii[i]
                glowLayer.shadowOpacity = cfg.opacities[i]
            }
            segments.append(s)
        }
        while segments.count > count {
            let s = segments.removeLast()
            for shape in s.all { shape.removeFromSuperlayer() }
        }
    }

    private func relayoutSegments() {
        let count = segments.count
        guard count > 0 else { return }
        switch shape {
        case .notch:        relayoutNotchSegments(count: count)
        case .bar(let w):   relayoutBarSegments(width: w, count: count)
        }
    }

    /// Notch: all segments share the one stroked U-path and render their 1/N
    /// slice via strokeStart/strokeEnd. The U is drawn clockwise from top-right
    /// (strokeStart=0 is the right end), so segment 0 is mapped to the *left*
    /// end to match the left→right session-open order.
    private func relayoutNotchSegments(count: Int) {
        guard let path = cachedPath else { return }
        for (i, segment) in segments.enumerated() {
            let idx = count - 1 - i
            let start = CGFloat(idx) / CGFloat(count)
            let end = CGFloat(idx + 1) / CGFloat(count)
            for shape in segment.all {
                shape.path = path
                shape.frame = bounds
                shape.shadowPath = nil  // per-segment glow, not full U
                shape.strokeStart = start
                shape.strokeEnd = end
            }
        }
    }

    /// Bar: each segment gets its own closed, filled tapered slice of the bar
    /// (segment 0 = leftmost). The glow is the layer's shadow of that filled
    /// shape, so the halo tapers to a point at the bar's two outer ends along
    /// with the core.
    private func relayoutBarSegments(width: CGFloat, count: Int) {
        let yc = bounds.height - shape.glowPadding
        let x0 = (bounds.width - width) / 2
        let x1 = x0 + width
        let h: CGFloat = 5                  // core thickness across the flat middle
        // Very short taper: only the outer ~2.5% of each end is the elliptical
        // cap, so the bar reads as full-height with just its tips rounded off.
        let t = width * 0.025
        for (i, segment) in segments.enumerated() {
            let xa = x0 + width * CGFloat(i) / CGFloat(count)
            let xb = x0 + width * CGFloat(i + 1) / CGFloat(count)
            let segPath = barSegmentPath(xa: xa, xb: xb, x0: x0, x1: x1, yc: yc, h: h, t: t)
            for shape in segment.all {
                shape.path = segPath
                shape.frame = bounds
                shape.shadowPath = nil
                shape.strokeStart = 0
                shape.strokeEnd = 1
            }
        }
    }

    /// Force the view to a specific state — used only for the startup self-test.
    func previewState(_ state: MergedState) {
        apply(states: state == .idle ? [] : [state], animated: true)
    }

    static func cgColor(for state: MergedState) -> CGColor {
        switch state {
        case .working:
            // Amber #FFB000 — Claude actively running. Per design v10 palette.
            return NSColor(red: 255/255.0, green: 176/255.0, blue: 0/255.0, alpha: 1).cgColor
        case .waiting:
            // Green — your turn, Claude ready.
            return NSColor(red: 95/255.0, green: 207/255.0, blue: 122/255.0, alpha: 1).cgColor
        case .attention:
            // Green #5FCF7A — Claude paused for your input (Notification hook).
            // Same green as "waiting" by design: blue/green were hard to tell
            // apart, so attention now shares the color and is distinguished by
            // its faster pulse cadence and chime instead.
            return NSColor(red: 95/255.0, green: 207/255.0, blue: 122/255.0, alpha: 1).cgColor
        case .idle:
            // White — fully done / inactive.
            return NSColor.white.cgColor
        }
    }
}
