import Foundation
import IOKit.pwr_mgt
import Shared

// Root daemon: keeps the battery at or below the configured limit by toggling CHTE.
// Usage: plateau-helper [daemon|status|charge on|charge off]

// launchd redirects stdout to a file; without line buffering nothing shows up in the log.
setvbuf(stdout, nil, _IOLBF, 0)

func log(_ message: String) {
    let time = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withFullTime])
    print("\(time) \(message)")
}

let args = CommandLine.arguments.dropFirst()

switch args.first {
case "status":
    let inhibited = Charging.isInhibited().map { $0 ? "inhibited" : "allowed" } ?? "unknown"
    print("limit=\(Config.readLimit().map(String.init) ?? "unset") charging=\(inhibited) battery=\(BatterySnapshot.read()?.percent ?? -1)%")
    exit(0)
case "charge":
    let on = args.dropFirst().first == "on"
    exit(Charging.setInhibited(!on) ? 0 : 1)
default:
    break
}

guard getuid() == 0 else {
    FileHandle.standardError.write("daemon must run as root\n".data(using: .utf8)!)
    exit(1)
}

// Leave the charge state alone on SIGTERM: launchd also sends it at shutdown, and restoring charging
// then would let the Mac charge to 100% while off. uninstall-helper.sh restores charging explicitly.
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler {
    log("stopped")
    exit(0)
}
term.resume()

var limit = Config.readLimit() ?? Config.defaultLimit
var sleepAssertion: IOPMAssertionID = 0

func setPreventSleep(_ prevent: Bool) {
    if prevent && sleepAssertion == 0 {
        // Idle sleep only: closing the lid or choosing Sleep still sleeps the Mac normally.
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Plateau: charging to limit" as CFString, &sleepAssertion)
        log("preventing idle sleep until limit is reached")
    } else if !prevent && sleepAssertion != 0 {
        IOPMAssertionRelease(sleepAssertion)
        sleepAssertion = 0
        log("allowing idle sleep")
    }
}

/// Set between "will sleep" and "has powered on". macOS takes a few seconds to actually sleep after
/// telling us, and the periodic check must not undo the pre-sleep pause in that window.
var goingToSleep = false

func enforce() {
    if goingToSleep { return }
    let previousLimit = limit
    if let latest = Config.readLimit() { limit = latest }
    guard let battery = BatterySnapshot.read(), let inhibited = Charging.isInhibited() else {
        setPreventSleep(false)
        return
    }
    let target = Policy.shouldInhibit(percent: battery.percent, limit: limit, currentlyInhibited: inhibited,
                                      limitRaised: limit > previousLimit)
    if target != inhibited {
        Charging.setInhibited(target)
        log("battery \(battery.percent)% limit \(limit)% -> charging \(target ? "paused" : "resumed")")
    }
    setPreventSleep(Policy.shouldPreventSleep(percent: battery.percent, limit: limit,
                                              pluggedIn: battery.externalConnected, inhibited: target,
                                              chargeWatts: battery.batteryPower))
}

// Sleep/wake: pause charging before sleep when close to the limit, re-check on wake.
// iokit_common_msg() values from IOMessage.h (macros Swift can't import).
let messageCanSystemSleep: UInt32 = 0xE000_0270
let messageSystemWillSleep: UInt32 = 0xE000_0280
let messageSystemHasPoweredOn: UInt32 = 0xE000_0300

var rootPort: io_connect_t = 0
var powerPort: IONotificationPortRef?
var notifier: io_object_t = 0
rootPort = IORegisterForSystemPower(nil, &powerPort, { _, _, messageType, argument in
    switch messageType {
    case messageCanSystemSleep:
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case messageSystemWillSleep:
        goingToSleep = true
        if let battery = BatterySnapshot.read(),
           Policy.shouldInhibitForSleep(percent: battery.percent, limit: limit),
           Charging.isInhibited() == false {
            Charging.setInhibited(true)
            log("sleeping at \(battery.percent)% near limit \(limit)% -> charging paused")
        }
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case messageSystemHasPoweredOn:
        goingToSleep = false
        log("woke up")
        enforce()
    default:
        break
    }
}, &notifier)
if rootPort != 0, let powerPort {
    IONotificationPortSetDispatchQueue(powerPort, .main)
} else {
    log("couldn't register for sleep/wake notifications; limit is enforced only while awake")
}

enforce()
log("started, limit \(limit)%")
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 5, repeating: 5)
timer.setEventHandler(handler: enforce)
timer.resume()
dispatchMain()
