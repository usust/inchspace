import Darwin
import Foundation
import XCTest
@testable import inchspace

@MainActor
final class ArchiveAutopilotTests: XCTestCase {
    func testWorkspaceOrganizesInPlaceAndRemembersSettledFiles() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file("invoice-2026.txt")
        let original = try Data(contentsOf: source)
        let service = try await f.service()
        var planned = 0
        let autopilot = f.autopilot(service) { context in
            planned += 1
            let file = try XCTUnwrap(context.files.first)
            return f.response(file: file, directory: "Finance")
        }
        let summary = try await autopilot.run()
        XCTAssertEqual(summary.movedFiles, 1)
        XCTAssertEqual(summary.createdDirectories, 1)
        XCTAssertFalse(ArchiveFileSystem.exists(source))
        XCTAssertEqual(try Data(contentsOf: f.workspace.appendingPathComponent("Finance/invoice-2026.txt")), original)
        // A second pass finds nothing new and must not call the model again.
        let before = planned
        let again = try await autopilot.run()
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(planned, before)
    }

    func testEmptyPlanSettlesFilesWithoutChangingThem() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file("notes.txt")
        let service = try await f.service()
        var calls = 0
        let autopilot = f.autopilot(service) { _ in
            calls += 1
            return ArchiveAIResponse(summary: "已经很整齐", directories: [], files: [])
        }
        _ = try await autopilot.run()
        _ = try await autopilot.run()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(ArchiveFileSystem.exists(source))
    }

    func testInvalidPlanIsRetriedThenLeftUntouched() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file("invoice.txt")
        let service = try await f.service()
        var calls = 0
        let autopilot = f.autopilot(service) { context in
            calls += 1
            let file = try XCTUnwrap(context.files.first)
            return f.response(file: file, directory: "../Escape")
        }
        let summary = try await autopilot.run()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(summary.leftUntouched, 1)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertTrue(ArchiveFileSystem.exists(source))
    }

    func testReportsPerFileStatusAsBatchesFinish() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file("invoice-2026.txt")
        let service = try await f.service()
        var autopilot = f.autopilot(service) { context in
            let file = try XCTUnwrap(context.files.first)
            return f.response(file: file, directory: "Finance")
        }
        var reported: [ArchiveFileActivity] = []
        autopilot.report = { reported += $0 }
        _ = try await autopilot.run()
        XCTAssertEqual(reported.map(\.status), [.processing, .completed])
        XCTAssertEqual(reported.last?.path, source.path)
        XCTAssertEqual(reported.last?.detail, "已归入“Finance”")
    }

    func testReportsSkippedFilesWhenNoValidPlanArrives() async throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.file("invoice.txt")
        let service = try await f.service()
        var autopilot = f.autopilot(service) { context in
            let file = try XCTUnwrap(context.files.first)
            return f.response(file: file, directory: "../Escape")
        }
        var reported: [ArchiveFileActivity] = []
        autopilot.report = { reported += $0 }
        _ = try await autopilot.run()
        XCTAssertEqual(reported.last?.status, .skipped)
    }

    func testUndoKeepsRestoredFileSettled() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file("invoice.txt")
        let service = try await f.service()
        var calls = 0
        let autopilot = f.autopilot(service) { context in
            calls += 1
            return f.response(file: try XCTUnwrap(context.files.first), directory: "Finance")
        }
        let summary = try await autopilot.run()
        let batch = try XCTUnwrap(summary.batchIDs.first)
        let snapshot = await service.snapshot()
        let plan = try XCTUnwrap(snapshot.ai?.plans.first { $0.id == batch })
        let moved = try XCTUnwrap(plan.files.first)
        try await service.undo(moved.id)
        try await service.markSettled([moved.source.path: moved.fingerprint], removing: [moved.destination.path])
        _ = try await autopilot.run()
        XCTAssertEqual(calls, 1, "A file the user restored must not be organized again.")
        XCTAssertTrue(ArchiveFileSystem.exists(source))
    }

    func testLocalPlannerSortsByExistingFolderThenFileType() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent("Taxes"), withIntermediateDirectories: true)
        let tax = try f.file("taxes-2025.pdf")
        let photo = try f.file("holiday.jpg")
        let unknown = try f.file("mystery.xyz")
        let nested = f.workspace.appendingPathComponent("Taxes/old.pdf")
        try Data("x".utf8).write(to: nested)
        let service = try await f.service()
        let autopilot = f.autopilot(service) { ArchiveLocalPlanner.plan($0) }
        let summary = try await autopilot.run()
        XCTAssertEqual(summary.movedFiles, 2)
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Taxes/taxes-2025.pdf")))
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("图片/holiday.jpg")))
        XCTAssertFalse(ArchiveFileSystem.exists(tax))
        XCTAssertFalse(ArchiveFileSystem.exists(photo))
        XCTAssertTrue(ArchiveFileSystem.exists(unknown), "Unknown types stay put.")
        XCTAssertTrue(ArchiveFileSystem.exists(nested), "Files already in a subfolder are not reshuffled.")
    }

    func testLocalPlannerSkipsTakenDestinationNames() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent("图片"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: f.workspace.appendingPathComponent("图片/a.jpg"))
        let clash = try f.file("a.jpg")
        let service = try await f.service()
        let summary = try await f.autopilot(service) { ArchiveLocalPlanner.plan($0) }.run()
        XCTAssertEqual(summary.movedFiles, 0)
        XCTAssertTrue(ArchiveFileSystem.exists(clash))
    }

    func testWorkspaceConfigurationValidates() throws {
        let f = try Fixture()
        defer { f.remove() }
        XCTAssertNoThrow(try ArchiveFileSystem.validateConfiguration(f.config, stateDirectory: f.state))
        var nested = f.config
        nested.folders.append(ArchiveFolder(role: .library, url: f.workspace.appendingPathComponent("Inside")))
        XCTAssertThrowsError(try ArchiveFileSystem.validateConfiguration(nested, stateDirectory: f.state, requiresDirectoryAccess: false))
    }

    private struct Fixture {
        let root: URL
        let workspace: URL
        let state: URL
        let folder: ArchiveFolder
        var config: ArchiveConfiguration { ArchiveConfiguration(folders: [folder]) }

        init() throws {
            let temporary = ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path
            guard let physical = realpath(temporary, nil) else { throw ArchiveError("No temp path") }
            root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
                .appendingPathComponent("archive-autopilot-tests-\(UUID().uuidString)", isDirectory: true)
            free(physical)
            workspace = root.appendingPathComponent("Workspace", isDirectory: true)
            state = root.appendingPathComponent("State", isDirectory: true)
            folder = ArchiveFolder(role: .workspace, url: workspace,
                                   directoryPermission: ArchiveDirectoryPermission(canCreate: true, canRemoveEmpty: true))
            for url in [workspace, state] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        }

        func file(_ name: String) throws -> URL {
            let url = workspace.appendingPathComponent(name)
            try Data("invoice accounting payable".utf8).write(to: url)
            return url
        }

        func service() async throws -> ArchiveService {
            let service = try ArchiveService(directory: state)
            var config = self.config
            config.stableSeconds = 0
            try await service.configure(config)
            return service
        }

        func autopilot(_ service: ArchiveService, planner: @escaping ArchiveAutopilot.Planner) -> ArchiveAutopilot {
            var autopilot = ArchiveAutopilot(service: service, planner: planner)
            autopilot.stableWait = .milliseconds(10)
            return autopilot
        }

        func response(file: ArchiveAIFile, directory: String) -> ArchiveAIResponse {
            ArchiveAIResponse(summary: "按用途归类",
                              directories: [ArchiveAIDirectoryRequest(action: .create, rootID: folder.id.uuidString,
                                                                      relativePath: directory, reason: "发票")],
                              files: [ArchiveAIFileRequest(fileID: file.id, rootID: folder.id.uuidString,
                                                           relativeDirectory: directory, reason: "包含发票关键词",
                                                           proposedName: file.source.lastPathComponent)])
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
