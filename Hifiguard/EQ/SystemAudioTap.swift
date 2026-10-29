import CoreAudio
import Foundation

/// Captures all system audio and plays it back through the EQ. Behind a protocol for tests.
@MainActor
protocol AudioTapping: AnyObject {
    /// Builds a tap + private aggregate on `outputUID` and starts rendering through `renderer`.
    /// The tap starts unmuted; `onSignal` fires once when the tap delivers real (non-silent) audio.
    func start(outputUID: String, renderer: EQRenderer, onSignal: @escaping @MainActor () -> Void) throws
    /// Muted = original audio is silenced while we read the tap ("muted when tapped").
    func setMuted(_ muted: Bool)
    func stop()
}

struct TapError: LocalizedError {
    let step: String
    let status: OSStatus
    var errorDescription: String? { "\(step) failed (\(status))" }
}

/// Core Audio process tap (macOS 14.2+). The tap belongs to this process: if Hifiguard quits or crashes,
/// the HAL destroys it and the original audio plays again.
@MainActor
final class SystemAudioTap: AudioTapping {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var description: CATapDescription?
    private var renderer: EQRenderer?
    private var signalSource: DispatchSourceUserDataOr?

    func start(outputUID: String, renderer: EQRenderer, onSignal: @escaping @MainActor () -> Void) throws {
        stop()
        do {
            try build(outputUID: outputUID, renderer: renderer, onSignal: onSignal)
        } catch {
            stop()
            throw error
        }
    }

    func setMuted(_ muted: Bool) {
        guard let description, tapID != AudioObjectID(kAudioObjectUnknown) else { return }
        description.muteBehavior = muted ? .mutedWhenTapped : .unmuted
        var addr = HAL.address(kAudioTapPropertyDescription)
        var ref = Unmanaged.passUnretained(description).toOpaque()
        AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &ref)
    }

    func stop() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        signalSource?.cancel()
        tapID = AudioObjectID(kAudioObjectUnknown)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
        description = nil
        renderer = nil
        signalSource = nil
    }

    private func build(outputUID: String, renderer: EQRenderer, onSignal: @escaping @MainActor () -> Void) throws {
        // Exclude ourselves, or our own output would be fed back into the tap.
        let ownProcess = HAL.processObject(pid: ProcessInfo.processInfo.processIdentifier)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        if #available(macOS 26.0, *), let bundleID = Bundle.main.bundleIdentifier {
            description.bundleIDs = [bundleID]
        }
        description.name = "Hifiguard EQ"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        self.description = description

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "Create tap")
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hifiguard EQ",
            kAudioAggregateDeviceUIDKey: "io.github.j0di3x.hifiguard.eq.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "Create aggregate device")
        aggregateID = device

        let source = DispatchSource.makeUserDataOrSource(queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onSignal() } }
        source.activate()
        signalSource = source
        renderer.signal = source
        self.renderer = renderer

        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { [unowned(unsafe) renderer] _, input, _, output, _ in
            renderer.render(input: input, output: output)
        }, "Create IO proc")
        procID = proc
        if let proc { useOnlyTapInput(device: device, proc: proc) }
        try check(AudioDeviceStart(device, proc), "Start audio")
    }

    /// Turns off the output device's own input streams (e.g. the AirPods mic) for our IO proc,
    /// so the aggregate never opens a headset mic and flips headphones to call mode.
    /// Taps are listed after sub-devices, so the tap is the last input stream.
    private func useOnlyTapInput(device: AudioObjectID, proc: AudioDeviceIOProcID) {
        let streams = HAL.streamCount(device, kAudioObjectPropertyScopeInput)
        guard streams > 1 else { return }
        let pointerSize = MemoryLayout<UnsafeMutableRawPointer>.size
        let size = pointerSize + 4 + 4 * streams
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(streams), toByteOffset: pointerSize, as: UInt32.self)
        for i in 0..<streams {
            raw.storeBytes(of: UInt32(i == streams - 1 ? 1 : 0), toByteOffset: pointerSize + 4 + 4 * i, as: UInt32.self)
        }
        var addr = HAL.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(size), raw)
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw TapError(step: step, status: status) }
    }
}
