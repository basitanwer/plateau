import SwiftUI
import Shared

/// Power-flow diagram: adapter on the left feeding the MacBook and battery on the right,
/// with animated dots showing which way power is moving.
struct PowerFlowView: View {
    let battery: BatterySnapshot

    private let card = CGSize(width: 84, height: 56)
    private let adapter = CGPoint(x: 46, y: 86)
    private let mac = CGPoint(x: 222, y: 32)
    private let cell = CGPoint(x: 222, y: 140)

    private var charging: Double { max(battery.batteryPower, 0) }
    private var discharging: Double { max(-battery.batteryPower, 0) }
    private var toMac: Double { min(battery.powerIn, battery.systemLoad) }
    /// Everything flowing out of the sources (adapter + battery), so each line's share adds up to 100%.
    private var totalFlow: Double { battery.powerIn + discharging }

    var body: some View {
        ZStack {
            FlowLine(path: curve(to: mac), active: battery.powerIn > 0.2 && battery.systemLoad > 0.2,
                     tint: .yellow, watts: toMac)
            FlowLine(path: curve(to: cell), active: charging > 0.2, tint: .green, watts: charging)
            FlowLine(path: Path { p in
                p.move(to: CGPoint(x: cell.x, y: cell.y - card.height / 2))
                p.addLine(to: CGPoint(x: mac.x, y: mac.y + card.height / 2))
            }, active: discharging > 0.2, tint: .orange, watts: discharging)

            share(toMac, active: battery.powerIn > 0.2 && battery.systemLoad > 0.2)
                .position(x: mac.x - card.width / 2 - 18, y: mac.y - 11)
            share(charging, active: charging > 0.2)
                .position(x: cell.x - card.width / 2 - 18, y: cell.y + 11)
            share(discharging, active: discharging > 0.2)
                .position(x: cell.x + 18, y: (cell.y + mac.y) / 2)

            NodeCard(icon: "powerplug.fill", title: battery.externalConnected ? "\(battery.adapterWatts)W" : "Unplugged",
                     value: battery.powerIn, tint: .yellow)
                .opacity(battery.externalConnected ? 1 : 0.5)
                .position(adapter)
            NodeCard(icon: "laptopcomputer", title: "MacBook", value: battery.systemLoad, tint: .blue)
                .position(mac)
            NodeCard(icon: batteryIcon, title: "\(battery.percent)%",
                     value: abs(battery.batteryPower), sign: battery.batteryPower > 0.2 ? "+" : battery.batteryPower < -0.2 ? "−" : "",
                     tint: discharging > 0.2 ? .orange : .green)
                .position(cell)
        }
        .frame(width: 268, height: 172)
    }

    private var batteryIcon: String {
        if charging > 0.2 { return "battery.100percent.bolt" }
        switch battery.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    @ViewBuilder
    private func share(_ watts: Double, active: Bool) -> some View {
        if active && totalFlow > 0.2 {
            Text("\(Int((watts / totalFlow * 100).rounded()))%")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func curve(to target: CGPoint) -> Path {
        Path { p in
            let start = CGPoint(x: adapter.x + card.width / 2, y: adapter.y)
            let end = CGPoint(x: target.x - card.width / 2, y: target.y)
            let midX = (start.x + end.x) / 2
            p.move(to: start)
            p.addCurve(to: end, control1: CGPoint(x: midX, y: start.y), control2: CGPoint(x: midX, y: end.y))
        }
    }
}

private struct NodeCard: View {
    let icon: String
    let title: String
    let value: Double
    var sign = ""
    let tint: Color

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            Text(sign + String(format: "%.1f W", value))
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .frame(width: 84, height: 56)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
    }
}

/// Drawn with Core Animation so the moving dots are animated by the window server,
/// not by re-rendering SwiftUI every frame.
private struct FlowLine: NSViewRepresentable {
    let path: Path
    let active: Bool
    let tint: Color
    let watts: Double

    func makeNSView(context: Context) -> FlowLineView { FlowLineView() }

    func updateNSView(_ view: FlowLineView, context: Context) {
        view.update(path: path.cgPath, active: active, tint: NSColor(tint),
                    // More watts, faster dots. Bucketed so small fluctuations don't restart the animation.
                    speed: 14 + (min(watts, 60) / 5).rounded() * 4)
    }
}

final class FlowLineView: NSView {
    private let track = CAShapeLayer()
    private let dots = CAShapeLayer()
    private var tint = NSColor.clear
    private var active = false
    private var speed = 0.0
    private let dashLength = 10.1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [track, dots] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        track.lineWidth = 3
        dots.lineWidth = 4
        dots.lineDashPattern = [0.1, 10]
    }

    required init?(coder: NSCoder) { fatalError() }

    // Match SwiftUI's top-left origin so the paths line up.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(path: CGPath, active: Bool, tint: NSColor, speed: Double) {
        track.path = path
        dots.path = path
        let restart = active != self.active || speed != self.speed || dots.animation(forKey: "flow") == nil
        self.active = active
        self.tint = tint
        self.speed = speed
        applyColors()
        dots.isHidden = !active
        if active && restart {
            startFlow()
        } else if !active {
            dots.removeAnimation(forKey: "flow")
        }
    }

    // Core Animation drops animations when the popover's window goes away; restart on reopen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && active && dots.animation(forKey: "flow") == nil { startFlow() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func startFlow() {
        let flow = CABasicAnimation(keyPath: "lineDashPhase")
        flow.fromValue = 0
        flow.toValue = -dashLength
        flow.duration = dashLength / speed
        flow.repeatCount = .infinity
        dots.add(flow, forKey: "flow")
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = (active ? tint.withAlphaComponent(0.25)
                                        : NSColor.secondaryLabelColor.withAlphaComponent(0.15)).cgColor
            dots.strokeColor = tint.cgColor
        }
        CATransaction.commit()
    }
}
