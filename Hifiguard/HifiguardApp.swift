import AppKit
import SwiftUI

@main
struct HifiguardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(lock: appDelegate.lock, eq: appDelegate.eq)
        } label: {
            MenuBarLabel(lock: appDelegate.lock)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let lock: HiFiLock
    let eq: EQController

    /// When the app hosts unit tests it must not touch the real default device.
    private static var isHostingTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    override init() {
        let system: AudioSystem = Self.isHostingTests ? InertAudioSystem() : CoreAudioSystem()
        lock = HiFiLock(system: system, defaults: .standard)
        eq = EQController(system: system, tap: SystemAudioTap(), defaults: .standard)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        lock.start()
        eq.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        eq.stop()
        lock.stop()
    }

    @objc private func didWake(_ notification: Notification) {
        lock.evaluate()
        eq.rebuild()
    }
}
