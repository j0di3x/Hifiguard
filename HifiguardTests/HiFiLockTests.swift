import XCTest
@testable import Hifiguard

@MainActor
final class HiFiLockTests: XCTestCase {
    private var system: FakeAudioSystem!
    private var defaults: UserDefaults!
    private var clock: Date!

    override func setUp() async throws {
        system = FakeAudioSystem()
        defaults = UserDefaults(suiteName: "HifiguardTests-\(UUID().uuidString)")
        clock = Date(timeIntervalSince1970: 0)
        system.devices = [Devices.builtInMic, Devices.speakers]
        system.defaultInputID = Devices.builtInMic.id
    }

    private func makeLock() -> HiFiLock {
        let lock = HiFiLock(system: system, defaults: defaults, now: { [unowned self] in self.clock })
        lock.start()
        return lock
    }

    private func connectAirPods(asDefaultInput: Bool = true) {
        system.devices.append(Devices.airPods)
        system.sampleRates[Devices.airPods.id] = 48_000
        if asDefaultInput { system.defaultInputID = Devices.airPods.id }
        system.fire()
    }

    func testEnabledByDefault() {
        XCTAssertTrue(makeLock().isEnabled)
    }

    func testNoHeadphonesStatus() {
        let lock = makeLock()
        XCTAssertEqual(lock.status, .noHeadphones)
        XCTAssertTrue(system.setCalls.isEmpty)
    }

    func testSwitchesToBuiltInWhenAirPodsBecomeDefaultInput() {
        let lock = makeLock()
        connectAirPods()
        XCTAssertEqual(system.defaultInputID, Devices.builtInMic.id)
        XCTAssertEqual(lock.status, .hiFi)
    }

    func testDoesNothingWhenDisabled() {
        let lock = makeLock()
        lock.isEnabled = false
        connectAirPods()
        XCTAssertEqual(system.defaultInputID, Devices.airPods.id)
        XCTAssertTrue(system.setCalls.isEmpty)
    }

    func testUsesPreferredMicWhenPresent() {
        system.devices.append(Devices.usbMic)
        let lock = makeLock()
        lock.preferredMicUID = Devices.usbMic.uid
        connectAirPods()
        XCTAssertEqual(system.defaultInputID, Devices.usbMic.id)
    }

    func testFallsBackToBuiltInWhenPreferredMicMissing() {
        defaults.set("Unplugged", forKey: HiFiLock.Keys.preferredMic)
        let lock = makeLock()
        connectAirPods()
        XCTAssertEqual(system.defaultInputID, Devices.builtInMic.id)
        XCTAssertEqual(lock.status, .hiFi)
    }

    func testNoReplacementMicWhenOnlyBluetoothInputs() {
        system.devices = [Devices.speakers]
        system.defaultInputID = nil
        let lock = makeLock()
        connectAirPods()
        XCTAssertEqual(system.defaultInputID, Devices.airPods.id)
        XCTAssertEqual(lock.status, .noReplacementMic)
    }

    func testDisableRestoresPreviousInput() {
        let lock = makeLock()
        connectAirPods()
        lock.isEnabled = false
        XCTAssertEqual(system.defaultInputID, Devices.airPods.id)
    }

    func testStopRestoresPreviousInput() {
        let lock = makeLock()
        connectAirPods()
        lock.stop()
        XCTAssertEqual(system.defaultInputID, Devices.airPods.id)
        XCTAssertFalse(system.isListening)
    }

    func testRestoreSkippedIfUserPickedAnotherMicMeanwhile() {
        system.devices.append(Devices.usbMic)
        let lock = makeLock()
        connectAirPods()
        system.defaultInputID = Devices.usbMic.id
        system.fire()
        lock.isEnabled = false
        XCTAssertEqual(system.defaultInputID, Devices.usbMic.id)
    }

    func testRestoreSkippedIfPreviousDeviceGone() {
        let lock = makeLock()
        connectAirPods()
        system.devices.removeAll { $0 == Devices.airPods }
        system.fire()
        lock.isEnabled = false
        XCTAssertEqual(system.defaultInputID, Devices.builtInMic.id)
    }

    func testPinnedAppDetected() {
        let lock = makeLock()
        connectAirPods()
        system.inputUsers = [InputUser(name: "Zoom", deviceIDs: [Devices.airPods.id])]
        system.sampleRates[Devices.airPods.id] = 24_000
        system.fire()
        XCTAssertEqual(lock.status, .pinnedByApp(apps: ["Zoom"]))
        XCTAssertFalse(lock.status.isHiFi)
    }

    func testAppOnBuiltInMicKeepsHiFi() {
        let lock = makeLock()
        connectAirPods()
        system.inputUsers = [InputUser(name: "Voice Memos", deviceIDs: [Devices.builtInMic.id])]
        system.fire()
        XCTAssertEqual(lock.status, .hiFi)
    }

    func testCallModeWhenDisabledAndAppUsesHeadphoneMic() {
        let lock = makeLock()
        lock.isEnabled = false
        connectAirPods()
        system.inputUsers = [InputUser(name: "FaceTime", deviceIDs: [Devices.airPods.id])]
        system.fire()
        XCTAssertEqual(lock.status, .callMode(apps: ["FaceTime"]))
    }

    func testLowSampleRateMeansCallMode() {
        let lock = makeLock()
        connectAirPods()
        system.sampleRates[Devices.airPods.id] = 16_000
        system.fire()
        XCTAssertEqual(lock.status, .callMode(apps: []))
        system.sampleRates[Devices.airPods.id] = 48_000
        system.fire()
        XCTAssertEqual(lock.status, .hiFi)
    }

    func testWakeReevaluates() {
        let lock = makeLock()
        connectAirPods()
        system.defaultInputID = Devices.airPods.id  // changed while asleep, no notification
        lock.evaluate()
        XCTAssertEqual(system.defaultInputID, Devices.builtInMic.id)
    }

    func testGivesUpWhenSystemKeepsRevertingThenRetriesOnToggle() {
        let lock = makeLock()
        connectAirPods()
        for _ in 0..<HiFiLock.maxOverrides {
            clock += 1
            system.defaultInputID = Devices.airPods.id
            system.fire()
        }
        XCTAssertEqual(lock.status, .gaveUp)
        XCTAssertEqual(system.defaultInputID, Devices.airPods.id)

        lock.isEnabled = false
        lock.isEnabled = true
        XCTAssertEqual(system.defaultInputID, Devices.builtInMic.id)
        XCTAssertEqual(lock.status, .hiFi)
    }

    func testOverridesSpreadOverTimeDoNotGiveUp() {
        let lock = makeLock()
        connectAirPods()
        for _ in 0..<(HiFiLock.maxOverrides * 3) {
            clock += HiFiLock.fightWindow
            system.defaultInputID = Devices.airPods.id
            system.fire()
        }
        XCTAssertEqual(lock.status, .hiFi)
        XCTAssertEqual(system.defaultInputID, Devices.builtInMic.id)
    }

    func testSettingsPersist() {
        let lock = makeLock()
        lock.isEnabled = false
        lock.preferredMicUID = Devices.usbMic.uid
        let reloaded = HiFiLock(system: system, defaults: defaults)
        XCTAssertFalse(reloaded.isEnabled)
        XCTAssertEqual(reloaded.preferredMicUID, Devices.usbMic.uid)
    }
}
