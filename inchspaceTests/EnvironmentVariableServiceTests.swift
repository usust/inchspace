import Foundation
import XCTest
@testable import inchspace

final class EnvironmentVariableServiceTests: XCTestCase {
    private var root: URL!
    private var home: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "inchspace-env-tests-\(UUID().uuidString)")
        home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testParserRecognizesSupportedAssignmentForms() {
        let content = """
        export PLAIN=/one
        export DOUBLE="two words"
        export SINGLE='three words'
        SEPARATE=/four
        export SEPARATE
        """
        let parsed = ShellEnvironmentParser.parse(content, inheritedEnvironment: [:])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: parsed.definitions.map { ($0.name, $0.value) }), [
            "PLAIN": "/one", "DOUBLE": "two words", "SINGLE": "three words", "SEPARATE": "/four",
        ])
    }

    func testCreateUsesManagedBlockAndPreservesExistingContent() throws {
        let url = home.appending(path: ".zprofile")
        try "alias ll='ls -la'\n".write(to: url, atomically: true, encoding: .utf8)
        let service = makeService()

        try service.createEnvironmentVariable(name: "JAVA_HOME", value: "/Library/Java Home")

        let result = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(result.contains("alias ll='ls -la'"))
        XCTAssertTrue(result.contains(EnvironmentVariableService.managedStartMarker))
        XCTAssertTrue(result.contains("export JAVA_HOME='/Library/Java Home'"))
        XCTAssertEqual(service.getEnvironmentVariable("JAVA_HOME")?.effectiveValue, "/Library/Java Home")
    }

    func testUpdateExistingSourceDoesNotCreateDuplicate() throws {
        let url = home.appending(path: ".zshrc")
        try "export JAVA_HOME='/old'\nexport JAVA_HOME='/duplicate'\n".write(to: url, atomically: true, encoding: .utf8)
        let service = makeService()

        try service.updateEnvironmentVariable(name: "JAVA_HOME", value: "/new")

        let result = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(result.components(separatedBy: "JAVA_HOME").count - 1, 1)
        XCTAssertEqual(service.getEnvironmentVariable("JAVA_HOME")?.effectiveValue, "/new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: ".zprofile").path))
    }

    func testUpdateExplicitSourceOnlyTouchesRequestedFile() throws {
        let zshrc = home.appending(path: ".zshrc")
        let zprofile = home.appending(path: ".zprofile")
        try "export GOPATH='/zshrc'\n".write(to: zshrc, atomically: true, encoding: .utf8)
        try "export GOPATH='/zprofile'\n".write(to: zprofile, atomically: true, encoding: .utf8)
        let service = makeService(processEnvironment: ["HOME": home.path])

        try service.updateEnvironmentVariable(name: "GOPATH", value: "/tmp/go", destination: zprofile)

        XCTAssertEqual(try String(contentsOf: zprofile, encoding: .utf8), "export GOPATH='/tmp/go'\n")
        XCTAssertEqual(try String(contentsOf: zshrc, encoding: .utf8), "export GOPATH='/zshrc'\n")
    }

    func testSpecialCharactersRoundTrip() throws {
        let value = "My SDK $HOME \"quoted\" 'apostrophe' (arm64) & 中文"
        let service = makeService()
        try service.createEnvironmentVariable(name: "SPECIAL_VALUE", value: value)
        XCTAssertEqual(service.getEnvironmentVariable("SPECIAL_VALUE")?.effectiveValue, value)
    }

    func testDirectoryVariableCanBeExportedToPathIdempotently() throws {
        let directory = home.appending(path: "Android SDK/platform-tools", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = makeService(processEnvironment: ["PATH": "/usr/bin:/bin"])

        try service.createEnvironmentVariable(
            name: "ANDROID_PLATFORM_TOOLS",
            value: directory.path,
            exportToPath: true
        )

        let url = home.appending(path: ".zprofile")
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("# >>> inchspace PATH: ANDROID_PLATFORM_TOOLS >>>"))
        XCTAssertTrue(content.contains("case \":${PATH:-}:\" in"))
        let variable = try XCTUnwrap(service.getEnvironmentVariable("ANDROID_PLATFORM_TOOLS"))
        XCTAssertTrue(variable.sources.contains(where: \.isExportedToPath))
        XCTAssertEqual(service.getEnvironmentVariable("PATH")?.effectiveValue, "\(directory.path):/usr/bin:/bin")

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", "source \"$PROFILE\"; source \"$PROFILE\"; printf '%s' \"$PATH\""]
        process.environment = ["PROFILE": url.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let sourcedPath = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(sourcedPath.split(separator: ":").filter { String($0) == directory.path }.count, 1)
    }

    func testEditingAndUncheckingPathExportUpdatesOnlyManagedRule() throws {
        let service = makeService(processEnvironment: ["PATH": "/usr/bin"])
        let url = home.appending(path: ".zprofile")
        try service.createEnvironmentVariable(name: "TOOLS_HOME", value: "/old/tools", exportToPath: true)

        try service.updateEnvironmentVariable(name: "TOOLS_HOME", value: "/new/tools", destination: url)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("export TOOLS_HOME='/new/tools'"))
        XCTAssertTrue(service.getEnvironmentVariable("TOOLS_HOME")?.sources.first(where: { $0.fileURL != nil })?.isExportedToPath == true)

        try service.updateEnvironmentVariable(name: "TOOLS_HOME", value: "/new/tools", destination: url, exportToPath: false)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(content.contains("inchspace PATH: TOOLS_HOME"))
        XCTAssertFalse(service.getEnvironmentVariable("TOOLS_HOME")?.sources.first(where: { $0.fileURL != nil })?.isExportedToPath == true)
    }

    func testDisableAndEnableAlsoDisableAndRestorePathExport() throws {
        let service = makeService(processEnvironment: ["PATH": "/usr/bin"])
        let url = home.appending(path: ".zprofile")
        try service.createEnvironmentVariable(name: "TOOLS_HOME", value: "/tools", exportToPath: true)

        try service.disableEnvironmentVariable(name: "TOOLS_HOME", in: url)
        var content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("# [inchspace disabled PATH] TOOLS_HOME"))
        XCTAssertFalse(content.contains("# >>> inchspace PATH: TOOLS_HOME >>>"))

        try service.enableEnvironmentVariable(name: "TOOLS_HOME", in: url)
        content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(content.contains("# [inchspace disabled PATH] TOOLS_HOME"))
        XCTAssertTrue(content.contains("# >>> inchspace PATH: TOOLS_HOME >>>"))
    }

    func testDeleteRemovesOnlyTargetAndKeepsOtherConfiguration() throws {
        let url = home.appending(path: ".zprofile")
        let content = "# custom\nexport KEEP='yes'\nexport REMOVE_ME='no'\nalias gs='git status'\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
        let service = makeService()

        try service.deleteEnvironmentVariable(name: "REMOVE_ME")

        let result = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(result.contains("export KEEP='yes'"))
        XCTAssertTrue(result.contains("alias gs='git status'"))
        XCTAssertFalse(result.contains("REMOVE_ME"))
    }

    func testDeleteDisabledDefinitionRemovesItsMarker() throws {
        let url = home.appending(path: ".zprofile")
        try "export REMOVE_ME='value'\nexport KEEP='yes'\n".write(to: url, atomically: true, encoding: .utf8)
        let service = makeService()
        try service.disableEnvironmentVariable(name: "REMOVE_ME", in: url)

        try service.deleteEnvironmentVariable(name: "REMOVE_ME", from: [url])

        let result = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(result.contains("REMOVE_ME"))
        XCTAssertTrue(result.contains("export KEEP='yes'"))
    }

    func testPathIsDeduplicatedAndMissingDirectoriesAreKept() throws {
        let service = makeService(processEnvironment: ["PATH": "/tmp:/tmp/:/does-not-exist"])
        let entries = service.listPathEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.last?.path, "/does-not-exist")
        XCTAssertFalse(entries.last?.exists ?? true)
        XCTAssertThrowsError(try service.addPathEntry("/tmp/", to: entries))
    }

    func testMissingAndEmptyConfigurationFilesAreSupported() throws {
        let service = makeService()
        XCTAssertNoThrow(try service.createEnvironmentVariable(name: "FIRST", value: "one"))
        try "".write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try service.createEnvironmentVariable(
            name: "SECOND",
            value: "two",
            destination: home.appending(path: ".zshrc")
        ))
    }

    func testDisableAndEnableRoundTripPreservesOriginalDefinition() throws {
        let url = home.appending(path: ".zprofile")
        let original = "  export JAVA_HOME=\"/Library/Java Home\"\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        let service = makeService()

        try service.disableEnvironmentVariable(name: "JAVA_HOME", in: url)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("# [inchspace disabled]   export JAVA_HOME"))
        XCTAssertEqual(service.getEnvironmentVariable("JAVA_HOME")?.status, .disabled)
        XCTAssertEqual(service.getEnvironmentVariable("JAVA_HOME")?.sources.first?.isEnabled, false)

        try service.enableEnvironmentVariable(name: "JAVA_HOME", in: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        XCTAssertEqual(service.getEnvironmentVariable("JAVA_HOME")?.status, .missingDirectory)
    }

    func testDisableSeparatedAssignmentKeepsOtherStandaloneExportsActive() throws {
        let url = home.appending(path: ".zshrc")
        try "JAVA_HOME='/java'\nexport JAVA_HOME KEEP_ME\n".write(to: url, atomically: true, encoding: .utf8)
        let service = makeService()

        try service.disableEnvironmentVariable(name: "JAVA_HOME", in: url)
        let disabled = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(disabled.contains("# [inchspace disabled] JAVA_HOME='/java'"))
        XCTAssertTrue(disabled.contains("export KEEP_ME"))

        try service.enableEnvironmentVariable(name: "JAVA_HOME", in: url)
        let enabled = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(enabled.contains("export JAVA_HOME='/java'"))
        XCTAssertTrue(enabled.contains("export KEEP_ME"))
    }

    func testSystemAndOutsideHomeFilesAreRejected() throws {
        let service = makeService()
        let outside = root.appending(path: "outside-profile")
        try "export SAFE='yes'\n".write(to: outside, atomically: true, encoding: .utf8)
        let link = home.appending(path: ".zprofile")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(try service.updateEnvironmentVariable(name: "SAFE", value: "no", destination: link))
        XCTAssertThrowsError(try service.disableEnvironmentVariable(name: "SAFE", in: URL(fileURLWithPath: "/etc/profile")))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "export SAFE='yes'\n")
    }

    func testUnreadableEncodingFailsWithoutChangingOriginalFile() throws {
        let url = home.appending(path: ".zprofile")
        let original = Data([0xff, 0xfe, 0x00, 0x01])
        try original.write(to: url)
        let service = makeService()

        XCTAssertThrowsError(try service.updateEnvironmentVariable(name: "SAFE", value: "value"))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    private func makeService(processEnvironment: [String: String] = [:]) -> EnvironmentVariableService {
        EnvironmentVariableService(
            homeDirectory: home,
            processEnvironment: processEnvironment,
            updatesEnvironmentStore: false
        )
    }
}
