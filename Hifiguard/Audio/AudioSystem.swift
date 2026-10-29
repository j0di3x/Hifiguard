import Foundation

typealias DeviceID = UInt32

enum Transport: Equatable, Hashable {
    case builtIn, bluetooth, bluetoothLE, usb, other
}

struct AudioDevice: Equatable, Hashable, Identifiable {
    let id: DeviceID
    let uid: String
    let name: String
    let transport: Transport
    /// Has input streams and may be the default input device.
    let hasInput: Bool
    let hasOutput: Bool

    var isBluetooth: Bool { transport == .bluetooth || transport == .bluetoothLE }
}

/// A process that is currently capturing audio, and the input devices it captures from.
struct InputUser: Equatable {
    let name: String
    let deviceIDs: Set<DeviceID>
}

/// Everything the hi-fi lock needs from Core Audio. Lets the logic run in unit tests without hardware.
@MainActor
protocol AudioSystem: AnyObject {
    var devices: [AudioDevice] { get }
    var defaultInputID: DeviceID? { get }
    var defaultOutputID: DeviceID? { get }
    var inputUsers: [InputUser] { get }
    /// True when any process other than ours is playing audio.
    var isOtherAudioPlaying: Bool { get }
    func nominalSampleRate(_ id: DeviceID) -> Double?
    @discardableResult func setDefaultInput(_ id: DeviceID) -> Bool
    /// Adds a handler, called on the main queue whenever devices, defaults, sample rates or
    /// audio-using processes change.
    func startListening(_ onChange: @escaping @MainActor () -> Void)
    /// Removes all handlers.
    func stopListening()
}

/// Used when the app is hosting unit tests, so tests never touch the real default device.
@MainActor
final class InertAudioSystem: AudioSystem {
    var devices: [AudioDevice] { [] }
    var defaultInputID: DeviceID? { nil }
    var defaultOutputID: DeviceID? { nil }
    var inputUsers: [InputUser] { [] }
    var isOtherAudioPlaying: Bool { false }
    func nominalSampleRate(_ id: DeviceID) -> Double? { nil }
    func setDefaultInput(_ id: DeviceID) -> Bool { false }
    func startListening(_ onChange: @escaping @MainActor () -> Void) {}
    func stopListening() {}
}
