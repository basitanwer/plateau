import SwiftUI
import Combine
import Shared

/// How charging is limited on this Mac.
enum LimitMode {
    /// Our root daemon toggles the SMC charge-inhibit key (macOS 26 and earlier). Any limit 20-100.
    case helper
    /// macOS's own Charge Limit, enforced by firmware (macOS 27+, where the SMC keys are gated). 80-100.
    case native
    case unsupported

    static let detect: LimitMode = {
        if Charging.isInhibited() != nil { return .helper }
        if NativeChargeLimit.isSupported { return .native }
        return .unsupported
    }()
}

final class Model: ObservableObject {
    let mode = LimitMode.detect
    let nativeChoices = LimitMode.detect == .native ? NativeChargeLimit.available() : []
    @Published var battery = BatterySnapshot()
    @Published var inhibited: Bool?
    @Published var limit: Double
    @Published var helperInstalled = FileManager.default.fileExists(atPath: Config.daemonPlist)
    @Published var helperOutdated = false
    @Published var helperRunning = true
    @Published var systemLimit: Int?
    @Published var error: String?

    /// Poll quickly while the popover is open, lazily while only the menu bar label is visible.
    var visible = false {
        didSet {
            guard visible != oldValue else { return }
            if visible { checkHelperVersion() }
            refresh()
            schedule()
        }
    }

    private var timer: Timer?

    init() {
        switch mode {
        case .native: limit = Double(NativeChargeLimit.current() ?? 100)
        default: limit = Double(Config.readLimit() ?? Config.defaultLimit)
        }
        refresh()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let timer = Timer(timeInterval: visible ? 2 : 20, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = visible ? 0.2 : 5
        // .common so it keeps firing while the slider is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        // Only assign on change so SwiftUI doesn't re-render for nothing.
        if let snapshot = BatterySnapshot.read(), snapshot != battery { battery = snapshot }
        let inhibitedNow = Charging.isInhibited()
        if inhibitedNow != inhibited { inhibited = inhibitedNow }
        let installed = FileManager.default.fileExists(atPath: Config.daemonPlist)
        if installed != helperInstalled { helperInstalled = installed }
        // In helper mode, macOS's own limit still applies underneath ours.
        let system = mode == .helper ? NativeChargeLimit.current().flatMap { $0 < 100 ? $0 : nil } : nil
        if system != systemLimit { systemLimit = system }
    }

    /// The installed daemon is a copy; flag it when this build ships a different one.
    func checkHelperVersion() {
        guard let bundled = Bundle.main.path(forResource: "plateau-helper", ofType: nil) else { return }
        let installed = FileManager.default.contentsEqual(atPath: bundled, andPath: Config.installedHelper)
        let outdated = helperInstalled && !installed
        if outdated != helperOutdated { helperOutdated = outdated }

        // Installed isn't the same as running (e.g. a failed bootstrap or a crash loop).
        let launchctl = Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["print", "system/com.basitanwer.plateau.helper"]
        let output = Pipe()
        launchctl.standardOutput = output
        launchctl.standardError = FileHandle.nullDevice
        try? launchctl.run()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        launchctl.waitUntilExit()
        let running = !helperInstalled || text.contains("state = running")
        if running != helperRunning { helperRunning = running }
    }

    func saveLimit() {
        switch mode {
        case .native:
            if NativeChargeLimit.set(Int(limit)) {
                error = nil
            } else {
                error = "macOS rejected the charge limit."
            }
            limit = Double(NativeChargeLimit.current() ?? Int(limit))
        default:
            error = Config.writeLimit(Int(limit)) ? nil : "Couldn't save limit. Is the helper installed?"
        }
    }

    var limitRange: ClosedRange<Double> {
        mode == .native ? Double(nativeChoices.first ?? 80)...100 : 20...100
    }

    let limitStep: Double = 5

    /// The battery is being held at the limit (by our daemon or by the firmware).
    var heldAtLimit: Bool {
        switch mode {
        case .helper: return inhibited == true
        case .native: return limit < 100 && battery.percent >= Int(limit) - 1 && battery.batteryPower <= 0.3
        case .unsupported: return false
        }
    }

    func runAdminScript(_ name: String) {
        guard let script = Bundle.main.path(forResource: name, ofType: "sh") else {
            error = "\(name).sh missing from app bundle"
            return
        }
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script quoted form of \"\(escaped)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err { error = err[NSAppleScript.errorMessage] as? String } else { error = nil }
    }

    func installHelper() {
        runAdminScript("install-helper")
        Config.writeLimit(Int(limit))
        refresh()
        checkHelperVersion()
    }

    /// On macOS 27 the old SMC helper can't do anything; let the user remove it.
    func removeHelper() {
        runAdminScript("uninstall-helper")
        refresh()
    }

    var status: String {
        let b = battery
        if !b.externalConnected { return "On battery" }
        if heldAtLimit { return "Held at \(Int(limit))% limit" }
        if b.batteryPower < -0.5 { return "Adapter can't keep up" }
        if b.batteryPower > 0.3 { return "Charging" }
        if let systemLimit, b.percent >= systemLimit - 1 { return "Held at \(systemLimit)% by macOS" }
        if b.fullyCharged { return "Fully charged" }
        return "Plugged in, not charging"
    }

    var menuBarImage: NSImage {
        if battery.externalConnected && heldAtLimit,
           let plug = NSImage(systemSymbolName: "powerplug", accessibilityDescription: "Battery") {
            return plug
        }
        return Self.batteryIcon(percent: battery.percent, bolt: battery.externalConnected)
    }

    /// Menu-bar battery like the system one: dim outline, fill matching the charge level, and a
    /// bolt knocked out of the fill when plugged in. The SF Symbol bolt variant is always shown full.
    static func batteryIcon(percent: Int, bolt: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 25, height: 12), flipped: false) { _ in
            NSColor.black.withAlphaComponent(0.4).set()
            let body = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 21, height: 11), xRadius: 3.5, yRadius: 3.5)
            body.lineWidth = 1
            body.stroke()
            NSBezierPath(roundedRect: NSRect(x: 22.5, y: 4, width: 1.5, height: 4), xRadius: 0.75, yRadius: 0.75).fill()

            NSColor.black.set()
            let level = CGFloat(min(max(percent, 0), 100)) / 100
            if level > 0 {
                NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: max(17 * level, 2), height: 8),
                             xRadius: 1.5, yRadius: 1.5).fill()
            }

            if bolt {
                let shape = NSBezierPath()
                shape.move(to: NSPoint(x: 12.5, y: 11))
                shape.line(to: NSPoint(x: 7.5, y: 5.2))
                shape.line(to: NSPoint(x: 10.6, y: 5.2))
                shape.line(to: NSPoint(x: 9.5, y: 1))
                shape.line(to: NSPoint(x: 14.5, y: 6.8))
                shape.line(to: NSPoint(x: 11.4, y: 6.8))
                shape.close()
                // Clear a margin around the bolt so it reads against both the fill and the outline.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                shape.lineWidth = 2
                shape.stroke()
                shape.fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                shape.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Battery"
        return image
    }
}

struct ContentView: View {
    @ObservedObject var model: Model

    var body: some View {
        let b = model.battery
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(b.percent)%").font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(model.status).foregroundStyle(.secondary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Power flow").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                PowerFlowView(battery: b)
                    .frame(maxWidth: .infinity)
                if let m = b.timeRemaining {
                    Text(b.batteryPower < 0 ? "\(m / 60)h \(m % 60)m remaining" : "\(m / 60)h \(m % 60)m to full")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Charge limit")
                    Spacer()
                    Text("\(Int(model.limit))%").font(.system(.body, design: .monospaced))
                }
                Slider(value: $model.limit, in: model.limitRange, step: model.limitStep) { editing in
                    if !editing { model.saveLimit() }
                }
                .disabled(model.mode == .unsupported || (model.mode == .helper && !model.helperInstalled))
                if model.mode == .native {
                    Text("Uses macOS's built-in Charge Limit, which holds even while asleep. 100% turns it off.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.mode == .unsupported {
                    Text("This Mac doesn't support charge limiting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let systemLimit = model.systemLimit, Int(model.limit) > systemLimit {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macOS's own Charge Limit is set to \(systemLimit)%, so charging stops there. Set it to 100% to let this app control the limit.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Battery Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
                    }
                }
            }

            if model.mode == .native {
                if model.helperInstalled {
                    HStack {
                        Text("The old helper isn't needed on this macOS.").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Remove") { model.removeHelper() }
                    }
                }
            } else if model.mode == .unsupported {
                EmptyView()
            } else if !model.helperInstalled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A small background helper is needed to control charging (asks for your password once).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Install helper") { model.installHelper() }
                }
            } else if !model.helperRunning {
                HStack {
                    Text("The helper isn't running, so the limit isn't enforced.").font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Reinstall") { model.installHelper() }
                }
            } else if model.helperOutdated {
                HStack {
                    Text("A newer helper is available.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Update helper") { model.installHelper() }
                }
            }

            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = Model()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var observer: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingController(rootView: ContentView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageLeading

        observer = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateButton() }
        updateButton()
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        button.image = model.menuBarImage
        button.title = " \(model.battery.percent)%"
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.visible = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            // Don't start with the Quit button focused.
            popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        model.visible = false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
