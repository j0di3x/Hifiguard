import Foundation
import Observation

struct AvailableRelease: Equatable {
    let version: String
    let url: URL
}

enum AppVersion {
    /// "v1.10" vs "1.9": numeric, component by component; a missing component counts as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}

/// Checks GitHub for a newer release at launch and every day at 9:00.
/// If the Mac is asleep at 9:00, the check runs when it wakes. One timer per day, no polling.
/// It only reports the update; the user downloads it.
@MainActor
@Observable
final class UpdateChecker {
    enum Keys {
        static let automatic = "checkForUpdatesAutomatically"
    }

    static let checkHour = 9
    static let releasesAPI = URL(string: "https://api.github.com/repos/j0di3x/Hifiguard/releases/latest")!

    private(set) var available: AvailableRelease?
    private(set) var isChecking = false
    /// Set only for checks the user started, so a failed background check never nags.
    private(set) var manualCheckMessage: String?

    var isAutomatic: Bool {
        didSet {
            guard isAutomatic != oldValue else { return }
            defaults.set(isAutomatic, forKey: Keys.automatic)
            if isAutomatic { scheduleNext() } else { nextCheck = nil; cancelTimer?() }
        }
    }

    @ObservationIgnored let currentVersion: String
    @ObservationIgnored private(set) var nextCheck: Date?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: () async throws -> AvailableRelease
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let schedule: (Date, @escaping @MainActor () -> Void) -> () -> Void
    @ObservationIgnored private var cancelTimer: (() -> Void)?
    /// The running check, so tests can await it.
    @ObservationIgnored private(set) var currentCheck: Task<Void, Never>?

    init(currentVersion: String,
         defaults: UserDefaults,
         fetch: @escaping () async throws -> AvailableRelease = UpdateChecker.fetchLatestFromGitHub,
         now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current,
         schedule: @escaping (Date, @escaping @MainActor () -> Void) -> () -> Void = UpdateChecker.wallClockTimer) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.fetch = fetch
        self.now = now
        self.calendar = calendar
        self.schedule = schedule
        isAutomatic = defaults.object(forKey: Keys.automatic) as? Bool ?? true
    }

    func start() {
        guard isAutomatic else { return }
        check(manual: false)
        scheduleNext()
    }

    /// Catches up on a 9:00 check missed while asleep.
    func didWake() {
        guard isAutomatic, let nextCheck, now() >= nextCheck else { return }
        check(manual: false)
        scheduleNext()
    }

    func checkNow() {
        check(manual: true)
    }

    /// The first `checkHour`:00 strictly after `date`.
    static func nextCheckDate(after date: Date, calendar: Calendar) -> Date {
        let today = calendar.date(bySettingHour: checkHour, minute: 0, second: 0, of: date)!
        return today > date ? today : calendar.date(byAdding: .day, value: 1, to: today)!
    }

    // MARK: Private

    private func check(manual: Bool) {
        guard !isChecking else { return }
        isChecking = true
        if manual { manualCheckMessage = nil }
        currentCheck = Task {
            defer { isChecking = false }
            do {
                let latest = try await fetch()
                available = AppVersion.isNewer(latest.version, than: currentVersion) ? latest : nil
                if manual && available == nil { manualCheckMessage = String(localized: "You're up to date.") }
            } catch {
                if manual { manualCheckMessage = String(localized: "Couldn't check for updates.") }
            }
        }
    }

    private func scheduleNext() {
        cancelTimer?()
        let next = Self.nextCheckDate(after: now(), calendar: calendar)
        nextCheck = next
        cancelTimer = schedule(next) { [weak self] in self?.didWake() }
    }

    // MARK: Live dependencies

    /// A wall-clock timer: if the deadline passes during sleep, it fires right after wake.
    static func wallClockTimer(at date: Date, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + max(0, date.timeIntervalSinceNow), leeway: .seconds(60))
        timer.setEventHandler { MainActor.assumeIsolated(work) }
        timer.activate()
        return { timer.cancel() }
    }

    static func fetchLatestFromGitHub() async throws -> AvailableRelease {
        struct Response: Decodable {
            let tag_name: String
            let html_url: URL
        }
        var request = URLRequest(url: releasesAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(Response.self, from: data)
        return AvailableRelease(version: release.tag_name, url: release.html_url)
    }
}
