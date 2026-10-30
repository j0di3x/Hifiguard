import AppKit
import ObjectiveC
import ServiceManagement
import SwiftUI
import XCTest
@testable import Hifiguard

private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

private extension NSApplication {
    @objc var screenshotIsActive: Bool { true }
}

private extension SMAppService {
    @objc var screenshotStatus: SMAppService.Status { .notRegistered }
}

/// Renders the real panel with sample devices for the README. Skipped unless
/// TEST_RUNNER_HIFIGUARD_SCREENSHOT_DIR is set, which is what Scripts/make-screenshots.sh does.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var system: FakeAudioSystem!
    private var tap: FakeTap!
    private var defaults: UserDefaults!
    /// The hosted test shares the app's bundle ID and isn't frontmost, so it would show this Mac's
    /// real login item and grey switches. Show the default state and active controls instead.
    private let overrides: [(AnyClass, Selector, Selector)] = [
        (NSApplication.self, #selector(getter: NSApplication.isActive), #selector(getter: NSApplication.screenshotIsActive)),
        (SMAppService.self, #selector(getter: SMAppService.status), #selector(getter: SMAppService.screenshotStatus)),
    ]

    private func swapOverrides() {
        for (type, original, replacement) in overrides {
            method_exchangeImplementations(class_getInstanceMethod(type, original)!,
                                           class_getInstanceMethod(type, replacement)!)
        }
    }

    private func outputDirectory() throws -> URL {
        let path = ProcessInfo.processInfo.environment["HIFIGUARD_SCREENSHOT_DIR"]
        try XCTSkipIf(path == nil, "Only runs from Scripts/make-screenshots.sh")
        return URL(fileURLWithPath: path!)
    }

    override func setUp() async throws {
        system = FakeAudioSystem()
        tap = FakeTap()
        defaults = UserDefaults(suiteName: "HifiguardScreenshots-\(UUID().uuidString)")
        system.devices = [Devices.builtInMic, Devices.speakers, Devices.airPods, Devices.usbMic]
        system.defaultInputID = Devices.builtInMic.id
        system.defaultOutputID = Devices.airPods.id
        system.sampleRates[Devices.airPods.id] = 48_000
        swapOverrides()
    }

    override func tearDown() async throws {
        swapOverrides()
    }

    private func render(_ name: String, into directory: URL, lock: HiFiLock, eq: EQController,
                        updates: UpdateChecker, appearance: NSAppearance.Name) throws {
        let panel = PanelView(lock: lock, eq: eq, updates: updates)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key)
        let host = NSHostingView(rootView: panel)
        host.frame.size = host.fittingSize

        // On screen and key (but invisible) so controls get Retina scale and their active colors.
        let window = KeyWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.alphaValue = 0
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        // Always 2x, whatever the screen this runs on.
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width) * 2, pixelsHigh: Int(host.bounds.height) * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func makeUpdates() -> UpdateChecker {
        UpdateChecker(currentVersion: "1.1", defaults: defaults,
                      fetch: { throw URLError(.notConnectedToInternet) },
                      schedule: { _, _ in {} })
    }

    func testHiFiWithEqualizer() throws {
        let directory = try outputDirectory()
        let lock = HiFiLock(system: system, defaults: defaults)
        lock.start()
        let eq = EQController(system: system, tap: tap, defaults: defaults, schedule: { _, _ in })
        eq.start()
        eq.isEnabled = true
        tap.deliverSignal()
        eq.select(EQPreset.all.first { $0.name == "Bass Boost" }!)

        try render("panel-light", into: directory, lock: lock, eq: eq, updates: makeUpdates(), appearance: .aqua)
        try render("panel-dark", into: directory, lock: lock, eq: eq, updates: makeUpdates(), appearance: .darkAqua)
    }

    func testAppPinnedToHeadphoneMic() throws {
        let directory = try outputDirectory()
        system.inputUsers = [InputUser(name: "Meeting App", deviceIDs: [Devices.airPods.id])]
        system.sampleRates[Devices.airPods.id] = 16_000
        let lock = HiFiLock(system: system, defaults: defaults)
        lock.start()
        let eq = EQController(system: system, tap: tap, defaults: defaults, schedule: { _, _ in })
        eq.start()

        try render("panel-call-mode", into: directory, lock: lock, eq: eq, updates: makeUpdates(), appearance: .darkAqua)
    }
}
