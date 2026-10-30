import AppKit

/// Offers to move the app into Applications when it is opened from a DMG, Downloads, etc.,
/// then restarts it from there and ejects the disk image.
enum AppMover {
    static let suppressKey = "suppressMoveToApplications"

    /// True unless the app already lives in an Applications folder or is a development build.
    static func shouldOffer(bundlePath: String, homeDirectory: String) -> Bool {
        let path = (bundlePath as NSString).standardizingPath
        if path.hasPrefix("/Applications/") || path.hasPrefix(homeDirectory + "/Applications/") { return false }
        let devBuildMarkers = ["/DerivedData/", "/hifiguard-build/", "/Build/Products/"]
        return !devBuildMarkers.contains { path.contains($0) }
    }

    /// Copies `source` into `directory`, atomically replacing an existing copy. Returns the installed URL.
    static func install(_ source: URL, into directory: URL, fileManager: FileManager = .default) throws -> URL {
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        let staging = directory.appendingPathComponent(".\(source.lastPathComponent).installing")
        try? fileManager.removeItem(at: staging)
        try fileManager.copyItem(at: source, to: staging)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        return destination
    }

    /// Shows the offer if appropriate. Returns true when the app is about to quit and relaunch.
    @MainActor
    static func offerIfNeeded(defaults: UserDefaults) -> Bool {
        let source = Bundle.main.bundleURL
        guard !defaults.bool(forKey: suppressKey),
              shouldOffer(bundlePath: source.path, homeDirectory: NSHomeDirectory()) else { return false }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Move Hifiguard to Applications?")
        alert.informativeText = String(localized: "Hifiguard will copy itself to your Applications folder and restart from there.")
        alert.addButton(withTitle: String(localized: "Move to Applications"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { defaults.set(true, forKey: suppressKey) }
        guard response == .alertFirstButtonReturn else { return false }

        do {
            quitOtherInstances()
            let installed: URL
            do {
                installed = try install(source, into: URL(fileURLWithPath: "/Applications"))
            } catch CocoaError.fileWriteNoPermission {
                // Not an admin user: fall back to ~/Applications.
                let userApps = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
                try FileManager.default.createDirectory(at: userApps, withIntermediateDirectories: true)
                installed = try install(source, into: userApps)
            }
            relaunch(installed, ejecting: diskImageVolume(holding: source))
            return true
        } catch {
            let failure = NSAlert()
            failure.messageText = String(localized: "Couldn't move Hifiguard")
            let hint = String(localized: "Drag Hifiguard into your Applications folder yourself.")
            failure.informativeText = "\(error.localizedDescription)\n\n\(hint)"
            failure.runModal()
            return false
        }
    }

    // MARK: Private

    @MainActor
    private static func quitOtherInstances() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != own }
            .forEach { $0.terminate() }
    }

    /// The mounted, read-only volume (our DMG) that holds the running app, if any.
    /// Works when macOS runs the app from a randomized "translocated" path, too.
    private static func diskImageVolume(holding source: URL) -> URL? {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsReadOnlyKey],
                                                            options: [.skipHiddenVolumes]) ?? []
        return volumes.first { volume in
            volume.path.hasPrefix("/Volumes/")
                && (try? volume.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
                && FileManager.default.fileExists(atPath: volume.appendingPathComponent(source.lastPathComponent).path)
        }
    }

    /// Waits for this process to exit, ejects the DMG, opens the installed copy, then quits us.
    @MainActor
    private static func relaunch(_ app: URL, ejecting volume: URL?) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
            while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
            [ -n "$1" ] && /usr/bin/hdiutil detach "$1" -quiet
            /usr/bin/open "$0"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, app.path, volume?.path ?? ""]
        try? process.run()
        NSApp.terminate(nil)
    }
}
