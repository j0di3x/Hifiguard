import Foundation
import Observation

enum EQStatus: Equatable {
    case off
    /// Tap running unmuted, our output silent, until the tap delivers real audio.
    case waitingForAudio
    case active
    /// Other apps play audio but the tap stays silent: System Audio Recording permission is missing.
    case needsPermission
    case noOutput
    case failed(String)

    var text: String {
        switch self {
        case .off: "Off"
        case .waitingForAudio: "On, waiting for audio"
        case .active: "On"
        case .needsPermission: "Needs System Audio Recording permission"
        case .noOutput: "No output device"
        case .failed(let reason): "Couldn't start: \(reason)"
        }
    }
}

/// Owns the EQ settings and the tap's lifecycle. The tap exists only while EQ is on.
@MainActor
@Observable
final class EQController {
    enum Keys {
        static let enabled = "eqEnabled"
        static let gains = "eqGains"
        static let preset = "eqPreset"
        static let limiter = "eqLimiter"
    }

    /// How long other apps may play into a silent tap before we call it a permission problem.
    static let permissionGrace: TimeInterval = 3

    private(set) var status: EQStatus = .off
    private(set) var gains: [Float]
    /// nil = custom gains.
    private(set) var presetName: String?

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            apply()
        }
    }

    var isLimiterOn: Bool {
        didSet {
            guard isLimiterOn != oldValue else { return }
            defaults.set(isLimiterOn, forKey: Keys.limiter)
            pushParameters()
        }
    }

    @ObservationIgnored let parameters = EQParameters()
    @ObservationIgnored private let system: AudioSystem
    @ObservationIgnored private let tap: AudioTapping
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    @ObservationIgnored private(set) var renderer: EQRenderer?
    @ObservationIgnored private var running: (outputUID: String, sampleRate: Double)?
    @ObservationIgnored private var permissionCheckPending = false

    init(system: AudioSystem,
         tap: AudioTapping,
         defaults: UserDefaults,
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
         }) {
        self.system = system
        self.tap = tap
        self.defaults = defaults
        self.schedule = schedule
        isEnabled = defaults.bool(forKey: Keys.enabled)
        isLimiterOn = defaults.object(forKey: Keys.limiter) as? Bool ?? true
        let saved = (defaults.array(forKey: Keys.gains) as? [Double])?.map(Float.init) ?? []
        gains = saved.count == EQBands.count ? saved : EQBands.flat
        let savedPreset = defaults.string(forKey: Keys.preset) ?? "Flat"
        presetName = savedPreset.isEmpty ? nil : savedPreset
    }

    func start() {
        pushParameters()
        system.startListening { [weak self] in self?.apply() }
        apply()
    }

    func stop() {
        tearDown()
    }

    /// Fresh tap, e.g. after wake.
    func rebuild() {
        tearDown()
        apply()
    }

    func setGain(_ band: Int, _ value: Float) {
        guard gains.indices.contains(band) else { return }
        gains[band] = min(max(value, EQBands.gainRange.lowerBound), EQBands.gainRange.upperBound)
        presetName = EQPreset.all.first(where: { $0.gains == gains })?.name
        saveGains()
    }

    func select(_ preset: EQPreset) {
        gains = preset.gains
        presetName = preset.name
        saveGains()
    }

    /// Re-checks output device and sample rate; (re)builds or tears down the tap as needed.
    func apply() {
        guard isEnabled else {
            tearDown()
            status = .off
            return
        }
        guard let outputID = system.defaultOutputID,
              let output = system.devices.first(where: { $0.id == outputID }) else {
            tearDown()
            status = .noOutput
            return
        }
        let sampleRate = system.nominalSampleRate(outputID) ?? 48_000
        if let running, running.outputUID == output.uid, running.sampleRate == sampleRate {
            checkPermissionLater()
            return
        }

        tearDown()
        let renderer = EQRenderer(sampleRate: sampleRate, parameters: parameters)
        do {
            try tap.start(outputUID: output.uid, renderer: renderer) { [weak self] in self?.signalArrived() }
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        self.renderer = renderer
        running = (output.uid, sampleRate)
        status = .waitingForAudio
        checkPermissionLater()
    }

    // MARK: Private

    /// The tap delivers real audio, so permission is granted: silence the original, play ours.
    private func signalArrived() {
        guard let renderer, status == .waitingForAudio || status == .needsPermission else { return }
        tap.setMuted(true)
        renderer.setOutputEnabled(true)
        status = .active
    }

    private func checkPermissionLater() {
        guard status == .waitingForAudio, !permissionCheckPending, system.isOtherAudioPlaying else { return }
        permissionCheckPending = true
        schedule(Self.permissionGrace) { [weak self] in
            guard let self else { return }
            permissionCheckPending = false
            if status == .waitingForAudio && system.isOtherAudioPlaying {
                status = .needsPermission
            }
        }
    }

    private func tearDown() {
        if running != nil { tap.stop() }
        renderer = nil
        running = nil
    }

    private func saveGains() {
        defaults.set(gains.map(Double.init), forKey: Keys.gains)
        defaults.set(presetName ?? "", forKey: Keys.preset)
        pushParameters()
    }

    private func pushParameters() {
        parameters.store(gains: gains, limiter: isLimiterOn)
    }
}
