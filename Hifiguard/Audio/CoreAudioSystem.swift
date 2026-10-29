import AppKit
import CoreAudio

/// Real `AudioSystem` backed by the Core Audio HAL. Event-driven: property listeners only, no timers.
@MainActor
final class CoreAudioSystem: AudioSystem {
    private struct Listener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let systemObject = HAL.systemObject
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var systemListeners: [Listener] = []
    private var objectListeners: [Listener] = []
    private var handlers: [@MainActor () -> Void] = []
    private var changePending = false

    // MARK: AudioSystem

    var devices: [AudioDevice] {
        HAL.objectIDs(systemObject, kAudioHardwarePropertyDevices).compactMap(device(for:))
    }

    var defaultInputID: DeviceID? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }
    var defaultOutputID: DeviceID? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    var inputUsers: [InputUser] {
        HAL.objectIDs(systemObject, kAudioHardwarePropertyProcessObjectList).compactMap { process in
            guard let running = HAL.uint32(process, kAudioProcessPropertyIsRunningInput), running != 0 else { return nil }
            let ids = Set(HAL.objectIDs(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput))
            guard !ids.isEmpty else { return nil }
            return InputUser(name: processName(process), deviceIDs: ids)
        }
    }

    var isOtherAudioPlaying: Bool {
        HAL.objectIDs(systemObject, kAudioHardwarePropertyProcessObjectList).contains { process in
            HAL.uint32(process, kAudioProcessPropertyIsRunningOutput) ?? 0 != 0
                && HAL.int32(process, kAudioProcessPropertyPID) != ownPID
        }
    }

    func nominalSampleRate(_ id: DeviceID) -> Double? {
        HAL.float64(id, kAudioDevicePropertyNominalSampleRate)
    }

    @discardableResult
    func setDefaultInput(_ id: DeviceID) -> Bool {
        var addr = HAL.address(kAudioHardwarePropertyDefaultInputDevice)
        var value = id
        return AudioObjectSetPropertyData(systemObject, &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &value) == noErr
    }

    func startListening(_ onChange: @escaping @MainActor () -> Void) {
        handlers.append(onChange)
        guard systemListeners.isEmpty else { return }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyProcessObjectList] {
            if let l = addListener(systemObject, selector, handler: { [weak self] in self?.topologyChanged() }) {
                systemListeners.append(l)
            }
        }
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            if let l = addListener(systemObject, selector, handler: { [weak self] in self?.scheduleChange() }) {
                systemListeners.append(l)
            }
        }
        registerObjectListeners()
    }

    func stopListening() {
        (systemListeners + objectListeners).forEach(remove)
        systemListeners = []
        objectListeners = []
        handlers = []
    }

    // MARK: Listeners

    private func topologyChanged() {
        registerObjectListeners()
        scheduleChange()
    }

    /// Per-device and per-process listeners. Rebuilt whenever the device or process list changes.
    private func registerObjectListeners() {
        objectListeners.forEach(remove)
        objectListeners = []
        let handler: @MainActor () -> Void = { [weak self] in self?.scheduleChange() }
        for device in HAL.objectIDs(systemObject, kAudioHardwarePropertyDevices) {
            if let l = addListener(device, kAudioDevicePropertyNominalSampleRate, handler: handler) {
                objectListeners.append(l)
            }
        }
        for process in HAL.objectIDs(systemObject, kAudioHardwarePropertyProcessObjectList) {
            for selector in [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput] {
                if let l = addListener(process, selector, handler: handler) {
                    objectListeners.append(l)
                }
            }
            if let l = addListener(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput, handler: handler) {
                objectListeners.append(l)
            }
        }
    }

    /// Coalesces bursts of HAL notifications into one evaluation.
    private func scheduleChange() {
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.changePending = false
                self.handlers.forEach { $0() }
            }
        }
    }

    private func addListener(_ object: AudioObjectID,
                             _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             handler: @escaping @MainActor () -> Void) -> Listener? {
        var addr = HAL.address(selector, scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &addr, .main, block) == noErr else { return nil }
        return Listener(object: object, address: addr, block: block)
    }

    private func remove(_ listener: Listener) {
        var addr = listener.address
        AudioObjectRemovePropertyListenerBlock(listener.object, &addr, .main, listener.block)
    }

    // MARK: Devices and processes

    private func defaultDevice(_ selector: AudioObjectPropertySelector) -> DeviceID? {
        guard let id = HAL.uint32(systemObject, selector), id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return id
    }

    private func device(for id: AudioObjectID) -> AudioDevice? {
        guard let uid = HAL.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let transport: Transport
        switch HAL.uint32(id, kAudioDevicePropertyTransportType) ?? 0 {
        case kAudioDeviceTransportTypeBuiltIn: transport = .builtIn
        case kAudioDeviceTransportTypeBluetooth: transport = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: transport = .bluetoothLE
        case kAudioDeviceTransportTypeUSB: transport = .usb
        default: transport = .other
        }
        let inputCapable = HAL.streamCount(id, kAudioObjectPropertyScopeInput) > 0
            && HAL.uint32(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeInput) != 0
        return AudioDevice(id: id,
                           uid: uid,
                           name: HAL.string(id, kAudioObjectPropertyName) ?? uid,
                           transport: transport,
                           hasInput: inputCapable,
                           hasOutput: HAL.streamCount(id, kAudioObjectPropertyScopeOutput) > 0)
    }

    private func processName(_ process: AudioObjectID) -> String {
        if let pid = HAL.int32(process, kAudioProcessPropertyPID),
           let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
            return name
        }
        return HAL.string(process, kAudioProcessPropertyBundleID) ?? "An app"
    }
}
