import XCTest
@testable import Hifiguard

final class AppMoverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AppMoverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOffersOutsideApplications() {
        let home = "/Users/someone"
        XCTAssertTrue(AppMover.shouldOffer(bundlePath: "/Volumes/Hifiguard 1.1/Hifiguard.app", homeDirectory: home))
        XCTAssertTrue(AppMover.shouldOffer(bundlePath: "/Users/someone/Downloads/Hifiguard.app", homeDirectory: home))
        XCTAssertTrue(AppMover.shouldOffer(
            bundlePath: "/private/var/folders/xy/T/AppTranslocation/1234/d/Hifiguard.app", homeDirectory: home))
    }

    func testNoOfferInsideApplicationsOrForDevBuilds() {
        let home = "/Users/someone"
        XCTAssertFalse(AppMover.shouldOffer(bundlePath: "/Applications/Hifiguard.app", homeDirectory: home))
        XCTAssertFalse(AppMover.shouldOffer(bundlePath: "/Users/someone/Applications/Hifiguard.app", homeDirectory: home))
        XCTAssertFalse(AppMover.shouldOffer(
            bundlePath: "/Users/someone/Library/Developer/Xcode/DerivedData/Hifiguard-abc/Build/Products/Debug/Hifiguard.app",
            homeDirectory: home))
    }

    private func makeApp(in directory: URL, marker: String) throws -> URL {
        let app = directory.appendingPathComponent("Hifiguard.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try marker.write(to: contents.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        return app
    }

    private func marker(of app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8)
    }

    func testInstallsIntoEmptyFolder() throws {
        let source = try makeApp(in: root.appendingPathComponent("dmg"), marker: "new")
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let installed = try AppMover.install(source, into: apps)
        XCTAssertEqual(installed.lastPathComponent, "Hifiguard.app")
        XCTAssertEqual(try marker(of: installed), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "source stays")
    }

    func testReplacesOlderCopy() throws {
        let source = try makeApp(in: root.appendingPathComponent("dmg"), marker: "new")
        let apps = root.appendingPathComponent("Applications")
        _ = try makeApp(in: apps, marker: "old")
        let installed = try AppMover.install(source, into: apps)
        XCTAssertEqual(try marker(of: installed), "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: apps.path)
        XCTAssertEqual(leftovers, ["Hifiguard.app"])
    }
}
