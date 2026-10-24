import XCTest
@testable import Shared

final class PolicyTests: XCTestCase {
    func testStopsAtLimit() {
        XCTAssertTrue(Policy.shouldInhibit(percent: 80, limit: 80, currentlyInhibited: false))
        XCTAssertTrue(Policy.shouldInhibit(percent: 95, limit: 80, currentlyInhibited: false))
    }

    func testChargesBelowLimit() {
        XCTAssertFalse(Policy.shouldInhibit(percent: 50, limit: 80, currentlyInhibited: true))
        XCTAssertFalse(Policy.shouldInhibit(percent: 78, limit: 80, currentlyInhibited: true))
    }

    func testHysteresisKeepsCurrentState() {
        XCTAssertTrue(Policy.shouldInhibit(percent: 79, limit: 80, currentlyInhibited: true))
        XCTAssertFalse(Policy.shouldInhibit(percent: 79, limit: 80, currentlyInhibited: false))
    }

    func testLimit100AlwaysCharges() {
        XCTAssertFalse(Policy.shouldInhibit(percent: 100, limit: 100, currentlyInhibited: true))
        XCTAssertFalse(Policy.shouldInhibit(percent: 99, limit: 100, currentlyInhibited: true))
    }

    func testFullCycle() {
        // Charge from 75 to the limit, drift down while plugged in, resume at limit - 2.
        var inhibited = false
        var log: [Bool] = []
        for percent in [75, 79, 80, 79, 78, 79, 80] {
            inhibited = Policy.shouldInhibit(percent: percent, limit: 80, currentlyInhibited: inhibited)
            log.append(inhibited)
        }
        XCTAssertEqual(log, [false, false, true, true, false, false, true])
    }

    func testRaisingLimitResumesInsideHysteresisBand() {
        XCTAssertTrue(Policy.shouldInhibit(percent: 84, limit: 85, currentlyInhibited: true))
        XCTAssertFalse(Policy.shouldInhibit(percent: 84, limit: 85, currentlyInhibited: true, limitRaised: true))
        XCTAssertTrue(Policy.shouldInhibit(percent: 85, limit: 85, currentlyInhibited: true, limitRaised: true))
    }

    func testPreventSleepOnlyWhileChargingTowardLimit() {
        XCTAssertTrue(Policy.shouldPreventSleep(percent: 60, limit: 80, pluggedIn: true, inhibited: false, chargeWatts: 20))
        XCTAssertFalse(Policy.shouldPreventSleep(percent: 60, limit: 80, pluggedIn: false, inhibited: false, chargeWatts: 0))
        XCTAssertFalse(Policy.shouldPreventSleep(percent: 80, limit: 80, pluggedIn: true, inhibited: true, chargeWatts: 0))
        XCTAssertFalse(Policy.shouldPreventSleep(percent: 60, limit: 100, pluggedIn: true, inhibited: false, chargeWatts: 20))
    }

    func testDoesNotKeepAwakeWhenSomethingElseHoldsTheBattery() {
        // macOS's own limit or a weak adapter: allowed to charge, but no power is going in.
        XCTAssertFalse(Policy.shouldPreventSleep(percent: 90, limit: 95, pluggedIn: true, inhibited: false, chargeWatts: 0.1))
        XCTAssertFalse(Policy.shouldPreventSleep(percent: 90, limit: 95, pluggedIn: true, inhibited: false, chargeWatts: -3))
    }

    func testSleepInhibitOnlyNearLimit() {
        XCTAssertTrue(Policy.shouldInhibitForSleep(percent: 76, limit: 80))
        XCTAssertTrue(Policy.shouldInhibitForSleep(percent: 75, limit: 80))
        XCTAssertFalse(Policy.shouldInhibitForSleep(percent: 74, limit: 80))
        XCTAssertFalse(Policy.shouldInhibitForSleep(percent: 30, limit: 80))
        XCTAssertFalse(Policy.shouldInhibitForSleep(percent: 99, limit: 100))
    }
}

final class BatteryTests: XCTestCase {
    func testSnapshotReadsRealHardware() throws {
        let snapshot = try XCTUnwrap(BatterySnapshot.read())
        XCTAssert((0...100).contains(snapshot.percent))
        if snapshot.externalConnected {
            XCTAssertGreaterThan(snapshot.adapterWatts, 0)
        }
        XCTAssertGreaterThan(snapshot.systemLoad, 0)
    }

    func testPowerReadingsAreLive() throws {
        // AppleSmartBattery alone refreshes ~once a minute; the SMC values should move within seconds.
        var loads = Set<Double>()
        for _ in 0..<6 {
            loads.insert(try XCTUnwrap(BatterySnapshot.read()).systemLoad)
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertGreaterThan(loads.count, 1, "system load didn't change over 3 s: \(loads)")
    }

    func testBatteryPowerMatchesFlow() throws {
        // Plugged in: adapter input ~= system load + battery charge. Battery current lags the other
        // readings by a second or so, so compare averages rather than a single snapshot.
        var inputs = 0.0, outputs = 0.0
        for _ in 0..<8 {
            let s = try XCTUnwrap(BatterySnapshot.read())
            guard s.externalConnected, s.powerIn > 1 else { return }
            inputs += s.powerIn
            outputs += s.systemLoad + s.batteryPower
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(inputs / 8, outputs / 8, accuracy: inputs / 8 * 0.25)
    }

    func testSomeChargeControlIsAvailable() {
        // SMC charge-inhibit key (macOS 26 and earlier) or macOS's own Charge Limit (macOS 27+).
        XCTAssert(Charging.isInhibited() != nil || NativeChargeLimit.isSupported)
    }
}

final class NativeChargeLimitTests: XCTestCase {
    // Read-only: never changes the Mac's charge limit.
    func testReadsNativeLimit() throws {
        try XCTSkipUnless(NativeChargeLimit.isSupported, "macOS Charge Limit not supported on this Mac")
        let available = NativeChargeLimit.available()
        XCTAssertEqual(available.last, 100)
        XCTAssertGreaterThanOrEqual(available.first ?? 0, 50)
        let current = try XCTUnwrap(NativeChargeLimit.current())
        XCTAssert(available.contains(current), "\(current) not in \(available)")
        print("macOS charge limit on this Mac: \(current)% (choices \(available))")
    }
}
