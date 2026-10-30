import Foundation
import Observation

enum LockStatus: Equatable {
    case noHeadphones
    case hiFi
    /// Headphones are in call mode (HFP). `apps` are the processes capturing from the headphone mic, if known.
    case callMode(apps: [String])
    /// An app captures from the headphone mic by device ID, so changing the default input cannot help.
    case pinnedByApp(apps: [String])
    /// Lock is on, but there is no non-Bluetooth mic to switch to.
    case noReplacementMic
    /// macOS kept switching the input back to the headphone mic; the lock stopped fighting it.
    case gaveUp

    var isHiFi: Bool { self == .hiFi || self == .noHeadphones }

    var title: String {
        switch self {
        case .noHeadphones: String(localized: "No Bluetooth headphones")
        case .hiFi: String(localized: "Hi-fi")
        case .callMode, .pinnedByApp: String(localized: "Call mode")
        case .noReplacementMic: String(localized: "No other mic to switch to")
        case .gaveUp: String(localized: "Paused: macOS keeps picking headphone mic")
        }
    }

    var detail: String? {
        switch self {
        case .callMode(let apps) where !apps.isEmpty:
            String(localized: "\(Self.list(apps)) using headphone mic")
        case .pinnedByApp(let apps):
            String(localized: "\(Self.list(apps)) chose headphone mic directly. Pick Mac mic in that app.")
        case .gaveUp:
            String(localized: "Turn Hi-fi Lock off and on to retry")
        default:
            nil
        }
    }

    private static func list(_ apps: [String]) -> String {
        apps.isEmpty ? String(localized: "An app") : apps.formatted(.list(type: .and))
    }
}

/// Keeps Bluetooth headphones in hi-fi (A2DP) by never letting their mic be the default input.
@MainActor
@Observable
final class HiFiLock {
    enum Keys {
        static let enabled = "hiFiLockEnabled"
        static let preferredMic = "replacementMicUID"
    }

    /// Overrides allowed inside `fightWindow` before giving up, so we never ping-pong with macOS.
    static let maxOverrides = 6
    static let fightWindow: TimeInterval = 10

    private(set) var status: LockStatus = .noHeadphones
    /// Non-Bluetooth input devices the user can pick as replacement.
    private(set) var replacementMics: [AudioDevice] = []

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            overrideTimes = []
            gaveUp = false
            if !isEnabled { restore() }
            evaluate()
        }
    }

    /// nil = built-in mic.
    var preferredMicUID: String? {
        didSet {
            guard preferredMicUID != oldValue else { return }
            defaults.set(preferredMicUID, forKey: Keys.preferredMic)
            evaluate()
        }
    }

    @ObservationIgnored private let system: AudioSystem
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    /// Input the system had before our latest override, restored on toggle off / quit.
    @ObservationIgnored private var restoreUID: String?
    /// Device we set as default; restore only if it is still the default (user did not change it since).
    @ObservationIgnored private var ourChoiceID: DeviceID?
    @ObservationIgnored private var overrideTimes: [Date] = []
    @ObservationIgnored private var gaveUp = false

    init(system: AudioSystem, defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.system = system
        self.defaults = defaults
        self.now = now
        self.isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        self.preferredMicUID = defaults.string(forKey: Keys.preferredMic)
    }

    func start() {
        system.startListening { [weak self] in self?.evaluate() }
        evaluate()
    }

    func stop() {
        system.stopListening()
        restore()
    }

    /// Re-checks everything. Called on every Core Audio change, on wake, and on settings change.
    func evaluate() {
        let devices = system.devices
        replacementMics = devices.filter { $0.hasInput && !$0.isBluetooth }
        if !devices.contains(where: \.isBluetooth) {
            // Headphones gone: a fresh connection gets a fresh try.
            gaveUp = false
            overrideTimes = []
        }

        if isEnabled, !gaveUp,
           let currentID = system.defaultInputID,
           let current = devices.first(where: { $0.id == currentID }), current.isBluetooth,
           let target = replacementTarget(in: devices) {
            override(current, with: target)
        }
        status = computeStatus(devices: devices)
    }

    // MARK: Private

    private func override(_ current: AudioDevice, with target: AudioDevice) {
        let t = now()
        overrideTimes = overrideTimes.filter { t.timeIntervalSince($0) < Self.fightWindow } + [t]
        if overrideTimes.count > Self.maxOverrides {
            gaveUp = true
            return
        }
        if system.setDefaultInput(target.id) {
            restoreUID = current.uid
            ourChoiceID = target.id
        }
    }

    private func restore() {
        defer {
            restoreUID = nil
            ourChoiceID = nil
        }
        guard let uid = restoreUID, let ours = ourChoiceID, system.defaultInputID == ours,
              let device = system.devices.first(where: { $0.uid == uid && $0.hasInput }) else { return }
        system.setDefaultInput(device.id)
    }

    private func replacementTarget(in devices: [AudioDevice]) -> AudioDevice? {
        let candidates = devices.filter { $0.hasInput && !$0.isBluetooth }
        if let uid = preferredMicUID, let preferred = candidates.first(where: { $0.uid == uid }) {
            return preferred
        }
        return candidates.first(where: { $0.transport == .builtIn }) ?? candidates.first
    }

    private func computeStatus(devices: [AudioDevice]) -> LockStatus {
        let btInputIDs = Set(devices.filter { $0.isBluetooth && $0.hasInput }.map(\.id))
        let btOutputs = devices.filter { $0.isBluetooth && $0.hasOutput }
        if btInputIDs.isEmpty && btOutputs.isEmpty { return .noHeadphones }

        let defaultIsBT = system.defaultInputID.map(btInputIDs.contains) ?? false
        if isEnabled && gaveUp && defaultIsBT { return .gaveUp }
        if isEnabled && defaultIsBT && replacementTarget(in: devices) == nil { return .noReplacementMic }

        let users = system.inputUsers.filter { !$0.deviceIDs.isDisjoint(with: btInputIDs) }
        let names = Array(Set(users.map(\.name))).sorted()
        if !users.isEmpty {
            return defaultIsBT ? .callMode(apps: names) : .pinnedByApp(apps: names)
        }
        // HFP runs at 8-24 kHz; A2DP at 44.1/48 kHz.
        if btOutputs.contains(where: { (system.nominalSampleRate($0.id) ?? 48_000) <= 24_000 }) {
            return .callMode(apps: [])
        }
        return .hiFi
    }
}
