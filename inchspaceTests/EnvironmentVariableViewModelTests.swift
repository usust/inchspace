import Foundation
import XCTest
@testable import inchspace

@MainActor
final class EnvironmentVariableViewModelTests: XCTestCase {
    func testCurrentAppEnvironmentIsNotDisplayed() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "inchspace-env-view-model-tests-\(UUID().uuidString)")
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "export CONFIGURED='/from-profile'\n".write(
            to: home.appending(path: ".zprofile"),
            atomically: true,
            encoding: .utf8
        )
        let service = EnvironmentVariableService(
            homeDirectory: home,
            processEnvironment: [
                "APP_ONLY": "injected",
                "CONFIGURED": "stale-process-value",
            ],
            updatesEnvironmentStore: false
        )
        let model = EnvironmentVariableViewModel(service: service, terminalManager: TerminalManager())

        model.load()

        XCTAssertEqual(model.filteredVariables.map(\.name), ["CONFIGURED"])
        let configured = try XCTUnwrap(model.filteredVariables.first)
        XCTAssertEqual(model.sources(for: configured).map(\.displayName), ["~/.zprofile"])
        XCTAssertEqual(model.displayedValue(for: configured), "/from-profile")
        XCTAssertFalse(model.sourceFilters.contains(.process))
    }
}
