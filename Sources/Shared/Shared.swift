import Foundation
import IOKit
import CSMC

public enum Config {
    public static let directory = "/Library/Application Support/Plateau"
    public static let limitFile = directory + "/limit"
    public static let daemonPlist = "/Library/LaunchDaemons/com.basitanwer.plateau.helper.plist"
    public static let installedHelper = "/Library/PrivilegedHelperTools/com.basitanwer.plateau.helper"
    public static let defaultLimit = 80

    /// nil if the file is missing or unreadable (e.g. caught mid-write), so callers can keep the last good value.
    /// Reads at most a few bytes: the root daemon shouldn't be made to slurp an arbitrary file.
    public static func readLimit() -> Int? {
        guard let handle = FileHandle(forReadingAtPath: limitFile) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8),
              let text = String(data: data, encoding: .utf8),
              let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return min(max(value, 20), 100)
    }

    @discardableResult
    public static func writeLimit(_ limit: Int) -> Bool {
        (try? "\(limit)\n".write(toFile: limitFile, atomically: false, encoding: .utf8)) != nil
    }
}

/// macOS's own Charge Limit (System Settings > Battery > Charging), through the private PowerUI client
/// that System Settings itself uses. The firmware enforces it, including during sleep and across reboots,
/// and it needs no root. On macOS 27 the SMC charge keys are gated, so this is the only way to limit
/// charging. Only the values from `available()` (80...100 in steps of 5) are accepted; 100 means off.
public enum NativeChargeLimit {
    private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type,
              cls.instancesRespond(to: NSSelectorFromString("setMCLLimit:error:"))
        else { return nil }
        let instance = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject
        return instance?.perform(NSSelectorFromString("initWithClientName:"), with: "Plateau")?
            .takeUnretainedValue() as? NSObject
    }()

    private static func imp<T>(_ name: String, as signature: T.Type) -> (NSObject, Selector, T)? {
        let selector = NSSelectorFromString(name)
        guard let client, client.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: client), selector) else { return nil }
        return (client, selector, unsafeBitCast(implementation, to: signature))
    }

    public static var isSupported: Bool {
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        guard let (c, sel, fn) = imp("isMCLSupported", as: Fn.self) else { return false }
        return fn(c, sel)
    }

    /// The active limit, or 100 when the limit is off.
    public static func current() -> Int? {
        typealias Enabled = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt64
        typealias Limit = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt8
        guard let (c, enabledSel, enabled) = imp("isMCLCurrentlyEnabled:", as: Enabled.self),
              let (_, limitSel, limit) = imp("getMCLLimitWithError:", as: Limit.self) else { return nil }
        var error: NSError?
        guard enabled(c, enabledSel, &error) != 0, error == nil else { return error == nil ? 100 : nil }
        let value = Int(limit(c, limitSel, &error))
        return error == nil ? value : nil
    }

    public static func available() -> [Int] {
        typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        guard let (c, sel, fn) = imp("availableChargeLimitsWithError:", as: Fn.self) else { return [] }
        var error: NSError?
        return ((fn(c, sel, &error) as? [NSNumber]) ?? []).map(\.intValue).sorted()
    }

    /// Snaps to the nearest accepted value (the private API is reported to crash below 80).
    @discardableResult
    public static func set(_ limit: Int) -> Bool {
        typealias Fn = @convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<NSError?>?) -> Bool
        let allowed = available()
        guard let value = allowed.min(by: { abs($0 - limit) < abs($1 - limit) }),
              let (c, sel, fn) = imp("setMCLLimit:error:", as: Fn.self) else { return false }
        var error: NSError?
        return fn(c, sel, UInt8(value), &error) && error == nil
    }
}

public enum Policy {
    /// Charging resumes once the battery drops this far below the limit, so the charger doesn't flap.
    public static let resumeBelow = 2
    /// When the Mac sleeps this close to the limit, charging is paused for the night so it can't overshoot.
    public static let sleepMargin = 5

    /// `limitRaised`: the limit went up since the last check, so charge toward it even inside the
    /// hysteresis band (otherwise 84% with a new limit of 85% would stay paused forever).
    public static func shouldInhibit(percent: Int, limit: Int, currentlyInhibited: Bool, limitRaised: Bool = false) -> Bool {
        if limit >= 100 { return false }
        if percent >= limit { return true }
        if percent <= limit - resumeBelow || limitRaised { return false }
        return currentlyInhibited
    }

    /// Prevent idle sleep (never lid-close sleep) while actually charging up to a limit, so the daemon
    /// is around to stop it. Requires real charge power: if macOS's own limit or a weak adapter holds
    /// the battery below our limit, we'd otherwise keep the Mac awake forever.
    public static func shouldPreventSleep(percent: Int, limit: Int, pluggedIn: Bool, inhibited: Bool, chargeWatts: Double) -> Bool {
        pluggedIn && limit < 100 && !inhibited && percent < limit && chargeWatts > 0.5
    }

    /// Whether to pause charging right before sleep (the daemon can't stop it once asleep).
    /// Far below the limit we keep charging, since running out matters more than a small overshoot.
    public static func shouldInhibitForSleep(percent: Int, limit: Int) -> Bool {
        limit < 100 && percent >= limit - sleepMargin
    }
}

/// Charge inhibit via the CHTE SMC key (ui32: 0 = charging allowed, 1 = inhibited).
public enum Charging {
    public static func isInhibited() -> Bool? {
        var bytes = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        var type = [CChar](repeating: 0, count: 5)
        guard smc_read("CHTE", &bytes, &size, &type) == 0 else { return nil }
        return bytes[0] != 0
    }

    /// Requires root.
    @discardableResult
    public static func setInhibited(_ inhibited: Bool) -> Bool {
        let bytes: [UInt8] = [inhibited ? 1 : 0, 0, 0, 0]
        return smc_write("CHTE", bytes, 4) == 0
    }
}

/// Live power readings from the SMC. AppleSmartBattery's telemetry only refreshes about once a
/// minute; these update every second.
enum LivePower {
    private static func read(_ key: String) -> (bytes: [UInt8], type: String)? {
        var bytes = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        var type = [CChar](repeating: 0, count: 5)
        guard smc_read(key, &bytes, &size, &type) == 0 else { return nil }
        return (bytes, String(cString: type))
    }

    static func float(_ key: String) -> Double? {
        guard let (b, type) = read(key), type == "flt " else { return nil }
        return Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
    }

    static func int16(_ key: String) -> Int? {
        guard let (b, type) = read(key) else { return nil }
        switch type {
        case "si16": return Int(Int16(bitPattern: UInt16(b[0]) | UInt16(b[1]) << 8))
        case "ui16": return Int(UInt16(b[0]) | UInt16(b[1]) << 8)
        default: return nil
        }
    }
}

public struct BatterySnapshot: Equatable {
    public var percent = 0
    public var externalConnected = false
    public var isCharging = false
    public var fullyCharged = false
    public var adapterWatts = 0
    public var adapterDescription = ""
    /// Watts drawn from the power adapter.
    public var powerIn = 0.0
    /// Watts consumed by the Mac itself.
    public var systemLoad = 0.0
    /// Watts into the battery (negative = discharging).
    public var batteryPower = 0.0
    public var timeRemaining: Int? // minutes

    public init() {}

    public static func read() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        // Fetch only the keys we use; the full property set includes large blobs (BatteryData etc).
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        var dict: [String: Any] = [:]
        for key in ["CurrentCapacity", "ExternalConnected", "IsCharging", "FullyCharged", "AdapterDetails",
                    "Voltage", "Amperage", "PowerTelemetryData", "TimeRemaining"] {
            dict[key] = prop(key)
        }

        func int(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? 0 }

        var s = BatterySnapshot()
        s.percent = Int(int(dict["CurrentCapacity"]))
        s.externalConnected = dict["ExternalConnected"] as? Bool ?? false
        s.isCharging = dict["IsCharging"] as? Bool ?? false
        s.fullyCharged = dict["FullyCharged"] as? Bool ?? false

        if let adapter = dict["AdapterDetails"] as? [String: Any] {
            s.adapterWatts = Int(int(adapter["Watts"]))
            s.adapterDescription = adapter["Description"] as? String ?? ""
        }

        let voltage = Double(int(dict["Voltage"]))
        let amperage = Double(int(dict["Amperage"]))
        s.batteryPower = voltage * amperage / 1_000_000

        if let telemetry = dict["PowerTelemetryData"] as? [String: Any] {
            s.powerIn = Double(int(telemetry["SystemPowerIn"])) / 1000
            s.systemLoad = Double(int(telemetry["SystemLoad"])) / 1000
        } else {
            s.systemLoad = max(-s.batteryPower, 0)
        }
        // Prefer the live SMC values: adapter input, total system power, battery current x voltage.
        if let powerIn = LivePower.float("PDTR") { s.powerIn = powerIn }
        if let load = LivePower.float("PSTR") { s.systemLoad = load }
        if let current = LivePower.int16("B0AC"), let volts = LivePower.int16("B0AV") {
            s.batteryPower = Double(current) * Double(volts) / 1_000_000
        }
        if !s.externalConnected { s.powerIn = 0 }

        let minutes = Int(int(dict["TimeRemaining"]))
        if minutes > 0 && minutes < 65535 { s.timeRemaining = minutes }
        return s
    }
}
