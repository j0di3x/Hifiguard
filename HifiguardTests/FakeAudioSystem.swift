import Foundation
@testable import Hifiguard

@MainActor
final class FakeAudioSystem: AudioSystem {
    var devices: [AudioDevice] = []
    var defaultInputID: DeviceID?
    var defaultOutputID: DeviceID?
    var inputUsers: [InputUser] = []
    var isOtherAudioPlaying = false
    var sampleRates: [DeviceID: Double] = [:]
    private(set) var setCalls: [DeviceID] = []
    var isListening: Bool { !handlers.isEmpty }
    private var handlers: [@MainActor () -> Void] = []

    func nominalSampleRate(_ id: DeviceID) -> Double? { sampleRates[id] }

    func setDefaultInput(_ id: DeviceID) -> Bool {
        setCalls.append(id)
        defaultInputID = id
        return true
    }

    func startListening(_ onChange: @escaping @MainActor () -> Void) {
        handlers.append(onChange)
    }

    func stopListening() {
        handlers = []
    }

    /// Simulates a Core Audio property change notification.
    func fire() { handlers.forEach { $0() } }
}

@MainActor
final class FakeTap: AudioTapping {
    struct Failure: Error {}

    private(set) var startedOutputs: [String] = []
    private(set) var stopCount = 0
    private(set) var isMuted = false
    private(set) var renderer: EQRenderer?
    var failNextStart = false
    private var onSignal: (@MainActor () -> Void)?

    func start(outputUID: String, renderer: EQRenderer, onSignal: @escaping @MainActor () -> Void) throws {
        if failNextStart {
            failNextStart = false
            throw Failure()
        }
        startedOutputs.append(outputUID)
        self.renderer = renderer
        self.onSignal = onSignal
        isMuted = false
    }

    func setMuted(_ muted: Bool) { isMuted = muted }

    func stop() {
        stopCount += 1
        onSignal = nil
        renderer = nil
    }

    /// Simulates the tap delivering its first non-silent audio.
    func deliverSignal() { onSignal?() }
}

enum Devices {
    static let builtInMic = AudioDevice(id: 1, uid: "BuiltInMic", name: "MacBook Pro Microphone",
                                        transport: .builtIn, hasInput: true, hasOutput: false)
    static let speakers = AudioDevice(id: 2, uid: "BuiltInSpeakers", name: "MacBook Pro Speakers",
                                      transport: .builtIn, hasInput: false, hasOutput: true)
    static let airPods = AudioDevice(id: 10, uid: "AirPods", name: "AirPods Pro",
                                     transport: .bluetooth, hasInput: true, hasOutput: true)
    static let usbMic = AudioDevice(id: 20, uid: "USBMic", name: "USB Mic",
                                    transport: .usb, hasInput: true, hasOutput: false)
}
