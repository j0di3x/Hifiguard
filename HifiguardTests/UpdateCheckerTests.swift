import XCTest
@testable import Hifiguard

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var clock: Date!
    private var latest: AvailableRelease!
    private var fetchCount = 0
    private var fetchFails = false
    private var timers: [(date: Date, work: @MainActor () -> Void)] = []
    private var calendar: Calendar!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "HifiguardUpdateTests-\(UUID().uuidString)")
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bratislava")!
        clock = date(2026, 10, 29, 8, 0)
        latest = AvailableRelease(version: "v1.0", url: URL(string: "https://example.com/r")!)
        fetchCount = 0
        fetchFails = false
        timers = []
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func makeChecker() -> UpdateChecker {
        UpdateChecker(currentVersion: "1.0", defaults: defaults,
                      fetch: { [unowned self] in
                          fetchCount += 1
                          if fetchFails { throw URLError(.notConnectedToInternet) }
                          return latest
                      },
                      now: { [unowned self] in clock },
                      calendar: calendar,
                      schedule: { [unowned self] date, work in
                          timers.append((date, work))
                          return {}
                      })
    }

    private func settle(_ checker: UpdateChecker) async {
        await checker.currentCheck?.value
    }

    func testVersionComparison() {
        XCTAssertTrue(AppVersion.isNewer("v1.1", than: "1.0"))
        XCTAssertTrue(AppVersion.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(AppVersion.isNewer("2", than: "1.9.9"))
        XCTAssertFalse(AppVersion.isNewer("v1.0", than: "1.0"))
        XCTAssertFalse(AppVersion.isNewer("1.0.0", than: "1.0"))
        XCTAssertFalse(AppVersion.isNewer("0.9", than: "1.0"))
    }

    func testNextCheckIsNineToday() {
        XCTAssertEqual(UpdateChecker.nextCheckDate(after: date(2026, 10, 29, 8, 0), calendar: calendar),
                       date(2026, 10, 29, 9, 0))
    }

    func testNextCheckIsNineTomorrowWhenPast() {
        XCTAssertEqual(UpdateChecker.nextCheckDate(after: date(2026, 10, 29, 9, 0), calendar: calendar),
                       date(2026, 10, 30, 9, 0))
        XCTAssertEqual(UpdateChecker.nextCheckDate(after: date(2026, 10, 29, 23, 30), calendar: calendar),
                       date(2026, 10, 30, 9, 0))
    }

    func testChecksAtLaunchAndSchedulesNine() async {
        let checker = makeChecker()
        checker.start()
        await settle(checker)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(timers.last?.date, date(2026, 10, 29, 9, 0))
        XCTAssertNil(checker.available)
    }

    func testFindsNewerRelease() async {
        latest = AvailableRelease(version: "v1.1", url: URL(string: "https://example.com/1.1")!)
        let checker = makeChecker()
        checker.start()
        await settle(checker)
        XCTAssertEqual(checker.available?.version, "v1.1")
    }

    func testTimerFiringChecksAndReschedules() async {
        let checker = makeChecker()
        checker.start()
        await settle(checker)
        clock = date(2026, 10, 29, 9, 0)
        timers.last!.work()
        await settle(checker)
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(timers.last?.date, date(2026, 10, 30, 9, 0))
    }

    func testWakeAfterMissedNineChecks() async {
        let checker = makeChecker()
        checker.start()
        await settle(checker)
        clock = date(2026, 10, 29, 13, 15)  // asleep through 9:00
        checker.didWake()
        await settle(checker)
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(timers.last?.date, date(2026, 10, 30, 9, 0))
    }

    func testWakeBeforeNineDoesNotCheck() async {
        let checker = makeChecker()
        checker.start()
        await settle(checker)
        clock = date(2026, 10, 29, 8, 30)
        checker.didWake()
        await settle(checker)
        XCTAssertEqual(fetchCount, 1)
    }

    func testAutomaticOffMeansNoChecks() async {
        defaults.set(false, forKey: UpdateChecker.Keys.automatic)
        let checker = makeChecker()
        checker.start()
        clock = date(2026, 10, 29, 13, 0)
        checker.didWake()
        await settle(checker)
        XCTAssertEqual(fetchCount, 0)
        XCTAssertTrue(timers.isEmpty)
    }

    func testBackgroundFailureIsSilentManualFailureIsShown() async {
        fetchFails = true
        let checker = makeChecker()
        checker.start()
        await settle(checker)
        XCTAssertNil(checker.manualCheckMessage)
        checker.checkNow()
        await settle(checker)
        XCTAssertEqual(checker.manualCheckMessage, String(localized: "Couldn't check for updates."))
    }

    func testManualCheckUpToDate() async {
        let checker = makeChecker()
        checker.checkNow()
        await settle(checker)
        XCTAssertEqual(checker.manualCheckMessage, String(localized: "You're up to date."))
    }
}
