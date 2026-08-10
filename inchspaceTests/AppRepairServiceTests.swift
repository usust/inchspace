import Foundation
import XCTest
@testable import inchspace

final class AppRepairServiceTests: XCTestCase {
    func testInspectFindsQuarantineWhenOnlyBundleRootHasAttribute() throws {
        let appURL = try makeTestApplication()
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        try setQuarantine(on: appURL)

        let report = try AppRepairService().inspect(appURL)

        XCTAssertTrue(report.hasQuarantine)
        XCTAssertTrue(report.needsRepair)
    }

    func testRepairRemovesQuarantineFromPathContainingSpaces() throws {
        let appURL = try makeTestApplication(name: "Quarantined Test App.app")
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        try setQuarantine(on: appURL)

        let report = try AppRepairService().repair(appURL)

        XCTAssertFalse(report.hasQuarantine)
        XCTAssertFalse(report.needsRepair)
    }

    private func makeTestApplication(name: String = "Test App.app") throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "inchspace-app-repair-\(UUID().uuidString)", directoryHint: .isDirectory)
        let appURL = directoryURL.appending(path: name, directoryHint: .isDirectory)
        let contentsURL = appURL.appending(path: "Contents", directoryHint: .isDirectory)
        let macOSURL = contentsURL.appending(path: "MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleExecutable": "TestExecutable",
            "CFBundleIdentifier": "vip.lylab.inchspace.tests.repair",
            "CFBundleName": "Test App",
            "CFBundleVersion": "1",
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appending(path: "Info.plist"))

        let executableURL = macOSURL.appending(path: "TestExecutable")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: executableURL.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: 0o755]
        ))
        return appURL
    }

    private func setQuarantine(on url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-w", "com.apple.quarantine", "0083;test;inchspace;", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
