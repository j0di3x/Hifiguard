import XCTest
@testable import Hifiguard

@MainActor
final class EQControllerTests: XCTestCase {
    private var system: FakeAudioSystem!
    private var tap: FakeTap!
    private var defaults: UserDefaults!
    private var scheduled: [@MainActor () -> Void] = []

    override func setUp() async throws {
        system = FakeAudioSystem()
        tap = FakeTap()
        defaults = UserDefaults(suiteName: "HifiguardEQTests-\(UUID().uuidString)")
        scheduled = []
        system.devices = [Devices.builtInMic, Devices.speakers]
        system.defaultOutputID = Devices.speakers.id
        system.sampleRates[Devices.speakers.id] = 48_000
    }

    private func makeEQ() -> EQController {
        let eq = EQController(system: system, tap: tap, defaults: defaults,
                              schedule: { [unowned self] _, work in self.scheduled.append(work) })
        eq.start()
        return eq
    }

    private func runScheduled() {
        let work = scheduled
        scheduled = []
        work.forEach { $0() }
    }

    func testOffByDefaultCreatesNoTap() {
        let eq = makeEQ()
        XCTAssertFalse(eq.isEnabled)
        XCTAssertEqual(eq.status, .off)
        XCTAssertTrue(tap.startedOutputs.isEmpty)
    }

    func testEnableStartsUnmutedTapAndWaitsForAudio() {
        let eq = makeEQ()
        eq.isEnabled = true
        XCTAssertEqual(tap.startedOutputs, [Devices.speakers.uid])
        XCTAssertFalse(tap.isMuted)
        XCTAssertEqual(eq.status, .waitingForAudio)
        XCTAssertEqual(tap.renderer?.isOutputEnabled, false)
    }

    func testSignalMutesOriginalAndEnablesOutput() {
        let eq = makeEQ()
        eq.isEnabled = true
        tap.deliverSignal()
        XCTAssertTrue(tap.isMuted)
        XCTAssertEqual(tap.renderer?.isOutputEnabled, true)
        XCTAssertEqual(eq.status, .active)
    }

    func testDisableStopsTap() {
        let eq = makeEQ()
        eq.isEnabled = true
        eq.isEnabled = false
        XCTAssertEqual(tap.stopCount, 1)
        XCTAssertEqual(eq.status, .off)
    }

    func testUnrelatedChangeDoesNotRebuild() {
        let eq = makeEQ()
        eq.isEnabled = true
        system.fire()
        XCTAssertEqual(tap.startedOutputs.count, 1)
        XCTAssertEqual(tap.stopCount, 0)
    }

    func testOutputChangeRebuildsOnNewDevice() {
        let eq = makeEQ()
        eq.isEnabled = true
        system.devices.append(Devices.airPods)
        system.defaultOutputID = Devices.airPods.id
        system.fire()
        XCTAssertEqual(tap.startedOutputs, [Devices.speakers.uid, Devices.airPods.uid])
        XCTAssertEqual(eq.status, .waitingForAudio)
    }

    func testSampleRateChangeRebuilds() {
        let eq = makeEQ()
        eq.isEnabled = true
        system.sampleRates[Devices.speakers.id] = 44_100
        system.fire()
        XCTAssertEqual(tap.startedOutputs.count, 2)
        XCTAssertEqual(tap.renderer?.sampleRate, 44_100)
    }

    func testNoOutputDevice() {
        system.defaultOutputID = nil
        let eq = makeEQ()
        eq.isEnabled = true
        XCTAssertEqual(eq.status, .noOutput)
        XCTAssertTrue(tap.startedOutputs.isEmpty)
    }

    func testSilentTapWhileOthersPlayMeansNoPermission() {
        let eq = makeEQ()
        system.isOtherAudioPlaying = true
        eq.isEnabled = true
        runScheduled()
        XCTAssertEqual(eq.status, .needsPermission)
        XCTAssertFalse(tap.isMuted, "Never mute the original without proof the tap works")
    }

    func testNoPermissionVerdictWithoutOtherAudio() {
        let eq = makeEQ()
        eq.isEnabled = true
        XCTAssertTrue(scheduled.isEmpty)
        system.isOtherAudioPlaying = true
        system.fire()
        tap.deliverSignal()
        runScheduled()
        XCTAssertEqual(eq.status, .active)
    }

    func testTapFailureIsReported() {
        let eq = makeEQ()
        tap.failNextStart = true
        eq.isEnabled = true
        guard case .failed = eq.status else { return XCTFail("expected failure, got \(eq.status)") }
    }

    func testRebuildAfterWake() {
        let eq = makeEQ()
        eq.isEnabled = true
        tap.deliverSignal()
        eq.rebuild()
        XCTAssertEqual(tap.startedOutputs.count, 2)
        XCTAssertFalse(tap.isMuted)
        XCTAssertEqual(eq.status, .waitingForAudio)
    }

    func testPresetsAndCustomGains() {
        let eq = makeEQ()
        XCTAssertEqual(eq.presetName, "Flat")
        let rock = EQPreset.all.first { $0.name == "Rock" }!
        eq.select(rock)
        XCTAssertEqual(eq.gains, rock.gains)
        eq.setGain(0, 20)
        XCTAssertEqual(eq.gains[0], 12)
        XCTAssertNil(eq.presetName)
        let (low, high) = eq.parameters.load()
        XCTAssertEqual(EQParameters.gain(0, low: low, high: high), 12)
    }

    func testSettingsPersist() {
        let eq = makeEQ()
        eq.isEnabled = true
        eq.isLimiterOn = false
        eq.setGain(3, -4)
        let reloaded = EQController(system: system, tap: FakeTap(), defaults: defaults)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertFalse(reloaded.isLimiterOn)
        XCTAssertEqual(reloaded.gains[3], -4)
        XCTAssertNil(reloaded.presetName)
    }
}
