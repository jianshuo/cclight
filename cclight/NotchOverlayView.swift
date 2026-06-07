import AppKit
import Combine
import QuartzCore
import CCLightCore

/// Per PROJECT.md: a low-key thin line wrapping the notch with a subtle halo
/// glow. Extended for multi-session: the U-shape outline is split into N equal
/// segments (capped at 4 by StateStore), each colored by its session's state.
///
/// Implementation: N `CAShapeLayer`s all stroke the same U-path but each uses
/// `strokeStart` / `strokeEnd` to render only its 1/N portion. Each layer
/// owns its own colored shadow so per-segment glows don't bleed into the full
/// U-shape (no shared `shadowPath`).
final class NotchOverlayView: NSView {
    private let notchSize: CGSize
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

    init(notchSize: CGSize) {
        self.notchSize = notchSize
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
        let b = bounds
        let cornerRadius: CGFloat = 12
        // notch centered horizontally, at the top of the view (AppDelegate
        // creates window as notchRect.insetBy(-glowPadding, -glowPadding)).
        let glowPadding: CGFloat = 90
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
        cachedPath = path
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
                shape.strokeColor = color
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
        while segments.count < count {
            let s = SegmentLayers()
            // Z-order: widest soft aura at bottom, crispest line on top.
            for shape in [s.glow5, s.glow4, s.glow3, s.glow2, s.glow1, s.line] {
                shape.fillColor = NSColor.clear.cgColor
                shape.lineCap = .butt
                shape.lineJoin = .round
                shape.lineWidth = 3.0
                shape.shadowOffset = .zero
                layer?.addSublayer(shape)
            }
            s.line.shadowOpacity = 0
            s.glow1.shadowOpacity = 1.0
            s.glow1.shadowRadius = 6
            s.glow2.shadowOpacity = 1.0
            s.glow2.shadowRadius = 14
            s.glow3.shadowOpacity = 0.9
            s.glow3.shadowRadius = 28
            s.glow4.shadowOpacity = 0.7
            s.glow4.shadowRadius = 50
            s.glow5.shadowOpacity = 0.4
            s.glow5.shadowRadius = 80
            segments.append(s)
        }
        while segments.count > count {
            let s = segments.removeLast()
            for shape in s.all { shape.removeFromSuperlayer() }
        }
    }

    private func relayoutSegments() {
        guard let path = cachedPath else { return }
        let count = segments.count
        guard count > 0 else { return }
        // The U-path is drawn clockwise starting at top-right, so strokeStart=0
        // is the right end. Map segment 0 to the *left* end instead, so the
        // visual order (left → right) matches the user's session-open order.
        for (i, segment) in segments.enumerated() {
            let reversed = count - 1 - i
            let start = CGFloat(reversed) / CGFloat(count)
            let end = CGFloat(reversed + 1) / CGFloat(count)
            for shape in segment.all {
                shape.path = path
                shape.frame = bounds
                shape.shadowPath = nil  // per-segment glow, not full U
                shape.strokeStart = start
                shape.strokeEnd = end
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
