import Darwin
import Foundation
import XCTest
@testable import inchspace

@MainActor
final class ArchiveAutopilotTests: XCTestCase {
    // MARK: Step 1 – one file at a time

    func testRenamesWithEvidenceAndRecordsEveryFile() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let scan = try f.file("scan INV-0042.pdf")
        let song = try f.file("aori - song.mp3")
        let service = try await f.service()
        var seen: [String] = []
        let autopilot = f.autopilot(service, planner: f.planner(review: { request in
            seen.append(request.file.source.lastPathComponent)
            let original = request.file.source.lastPathComponent
            let name = original == "scan INV-0042.pdf" ? "发票_INV-0042.pdf" : original
            return ArchiveFileDecision(proposedName: name, topic: "发票", folder: request.folder, reason: "关键词显示是发票")
        }))
        let summary = try await autopilot.run()
        XCTAssertEqual(summary.renamedFiles, 1)
        let renamed = f.workspace.appendingPathComponent("发票_INV-0042.pdf")
        XCTAssertTrue(ArchiveFileSystem.exists(renamed))
        XCTAssertFalse(ArchiveFileSystem.exists(scan))
        XCTAssertTrue(ArchiveFileSystem.exists(song), "A file the model keeps is not touched.")
        let records = await service.snapshot().files ?? [:]
        XCTAssertEqual(records[renamed.path]?.originalName, "scan INV-0042.pdf")
        XCTAssertEqual(records[renamed.path]?.renamed, true)
        XCTAssertEqual(records[song.path]?.renamed, false)
        XCTAssertNil(records[scan.path], "The record follows the file to its new name.")
        XCTAssertEqual(seen.count, 2, "Each file is reviewed on its own.")
    }

    func testFileMovesIntoExistingFolderThatFits() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent("Finance"), withIntermediateDirectories: true)
        let source = try f.file("invoice.txt")
        let service = try await f.service()
        var offered: [String] = []
        let autopilot = f.autopilot(service, planner: f.planner(review: { request in
            offered = request.folders
            return ArchiveFileDecision(proposedName: request.file.source.lastPathComponent, topic: "发票", folder: "finance", reason: "发票")
        }))
        let summary = try await autopilot.run()
        XCTAssertEqual(offered, ["Finance"])
        XCTAssertEqual(summary.movedFiles, 1)
        let destination = f.workspace.appendingPathComponent("Finance/invoice.txt")
        XCTAssertTrue(ArchiveFileSystem.exists(destination))
        XCTAssertFalse(ArchiveFileSystem.exists(source))
        let record = await service.snapshot().files?[destination.path]
        XCTAssertEqual(record?.stage, .grouped)
        XCTAssertEqual(record?.resolution, .organized)
    }

    func testFileIsNeverMovedToAFolderThatDoesNotExist() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file("invoice.txt")
        let service = try await f.service()
        let autopilot = f.autopilot(service, planner: f.planner(review: { request in
            ArchiveFileDecision(proposedName: request.file.source.lastPathComponent, topic: nil, folder: "Invented/Deep", reason: nil)
        }))
        let summary = try await autopilot.run()
        XCTAssertEqual(summary.movedFiles, 0)
        XCTAssertTrue(ArchiveFileSystem.exists(source))
    }

    func testUnchangedFilesAreNotNamedAgainAfterRestart() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file("notes.txt")
        var calls = 0
        let planner = f.planner(review: { request in
            calls += 1
            return ArchiveFileDecision(proposedName: request.file.source.lastPathComponent, folder: request.folder)
        })
        do {
            let service = try await f.service()
            _ = try await f.autopilot(service, planner: planner).run()
        }
        XCTAssertEqual(calls, 1)
        // A new service on the same database stands in for the app being reopened.
        let reopened = try ArchiveService(directory: f.state)
        _ = try await f.autopilot(reopened, planner: planner).run()
        XCTAssertEqual(calls, 1, "A recorded file whose fingerprint still matches is skipped.")
        try Data("changed content".utf8).write(to: source)
        _ = try await f.autopilot(reopened, planner: planner).run()
        XCTAssertEqual(calls, 2, "A changed file is processed again.")
    }

    func testRecordFollowsFileMovedWhileAppWasClosed() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file("notes.txt")
        var calls = 0
        let planner = f.planner(review: { request in
            calls += 1
            return ArchiveFileDecision(proposedName: request.file.source.lastPathComponent, folder: request.folder)
        })
        let service = try await f.service()
        _ = try await f.autopilot(service, planner: planner).run()
        let moved = f.workspace.appendingPathComponent("notes-renamed.txt")
        XCTAssertEqual(rename(source.path, moved.path), 0)
        _ = try await f.autopilot(service, planner: planner).run()
        XCTAssertEqual(calls, 1)
        let records = await service.snapshot().files ?? [:]
        XCTAssertNotNil(records[moved.path])
        XCTAssertNil(records[source.path])
    }

    func testUnsafeNamesAreCorrectedToTheConvention() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file("report-2026-10-19.txt")
        let service = try await f.service()
        let autopilot = f.autopilot(service, planner: f.planner(review: { request in
            // Drops the date and changes the extension: the extension is restored and the date put back in its field.
            ArchiveFileDecision(proposedName: "季度报告.md", folder: request.folder)
        }))
        let summary = try await autopilot.run()
        XCTAssertEqual(summary.renamedFiles, 1)
        XCTAssertFalse(ArchiveFileSystem.exists(source))
        let renamed = f.workspace.appendingPathComponent("季度报告_2026-10-19.txt")
        XCTAssertTrue(ArchiveFileSystem.exists(renamed))
        let wasRenamed = await service.snapshot().files?[renamed.path]?.renamed
        XCTAssertEqual(wasRenamed, true)
    }

    func testRenameNeverOverwritesAnExistingName() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let taken = try f.file("Invoice.txt")
        let source = try f.file("scan.txt")
        let service = try await f.service()
        let autopilot = f.autopilot(service, planner: f.planner(review: { request in
            let original = request.file.source.lastPathComponent
            return ArchiveFileDecision(proposedName: original == "scan.txt" ? "invoice.txt" : original, folder: request.folder)
        }))
        let summary = try await autopilot.run()
        XCTAssertEqual(summary.renamedFiles, 1)
        XCTAssertEqual(try String(contentsOf: taken, encoding: .utf8), "invoice accounting payable Invoice.txt")
        XCTAssertFalse(ArchiveFileSystem.exists(source))
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("invoice_2.txt")),
                      "A taken name gets the template's number field, never `(2)`.")
    }

    func testLooseFileWithoutAnswerIsCollectedInUnsortedFolder() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file("invoice.txt")
        let service = try await f.service()
        var calls = 0
        var autopilot = f.autopilot(service, planner: f.planner(review: { _ in
            calls += 1
            throw ArchiveError("格式无效")
        }))
        var reported: [ArchiveFileActivity] = []
        autopilot.report = { reported += $0 }
        let summary = try await autopilot.run()
        XCTAssertEqual(calls, 2, "A single file gets a second chance first.")
        XCTAssertEqual(summary.movedFiles, 1)
        let unsorted = f.workspace.appendingPathComponent("待分类/invoice.txt")
        XCTAssertTrue(ArchiveFileSystem.exists(unsorted))
        XCTAssertFalse(ArchiveFileSystem.exists(source))
        XCTAssertFalse(reported.contains { $0.status == .skipped }, "No file is left without a result.")
        let record = await service.snapshot().files?[unsorted.path]
        XCTAssertEqual(record?.resolution, .unplaced, "Looked at again once the folders change.")
        XCTAssertEqual(record?.previousFolder, "")
    }

    func testUnknownFileInASubfolderStaysWhereTheUserPutIt() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent("Vault"), withIntermediateDirectories: true)
        let source = f.workspace.appendingPathComponent("Vault/main.kdbx")
        try Data("db".utf8).write(to: source)
        let service = try await f.service()
        let summary = try await f.autopilot(service, planner: f.planner(review: { request in
            ArchiveFileDecision(proposedName: "renamed.kdbx", topic: "", folder: request.folder, known: false)
        })).run()
        XCTAssertEqual(summary.movedFiles + summary.renamedFiles, 0)
        XCTAssertTrue(ArchiveFileSystem.exists(source), "An unidentified file is never renamed or pulled out of its folder.")
        let record = await service.snapshot().files?[source.path]
        XCTAssertEqual(record?.resolution, .organized)
        XCTAssertFalse(record?.topic.isEmpty ?? true, "Without a topic from the model, the file's kind stands in.")
    }

    func testUnknownLooseFileJoinsClearlySimilarFilesAnywhereInTheTree() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent("Personal/Cloud Training"), withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: f.workspace.appendingPathComponent("Personal/Cloud Training/aws-solutions-architect.pdf"))
        _ = try f.file("aws solutions architect scan.jpg")
        let service = try await f.service()
        var offered: [String] = []
        let summary = try await f.autopilot(service, planner: f.planner(review: { request in
            offered = request.candidates.map(\.folder.path)
            return ArchiveFileDecision(proposedName: request.file.source.lastPathComponent, folder: "", known: false)
        })).run()
        XCTAssertEqual(offered.first, "Personal/Cloud Training", "The deep folder holding similar files is the first candidate.")
        XCTAssertEqual(summary.movedFiles, 1)
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Personal/Cloud Training/aws-solutions-architect-scan.jpg")),
                      "Moved under a name that follows the folder's pattern.")
    }

    func testModelThatAnswersNothingStopsTheRunWithoutMovingFiles() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let first = try f.file("a.txt")
        let second = try f.file("b.txt")
        let service = try await f.service()
        var autopilot = f.autopilot(service, planner: f.planner(review: { _ in throw ArchiveError("模型只输出了思考过程") }))
        autopilot.reviewBatch = 2
        do {
            _ = try await autopilot.run()
            XCTFail("A model that never answers must stop the run.")
        } catch let error as ArchiveNeedsReview {
            XCTAssertTrue(error.message.contains("模型只输出了思考过程"))
        }
        XCTAssertTrue(ArchiveFileSystem.exists(first))
        XCTAssertTrue(ArchiveFileSystem.exists(second))
        XCTAssertFalse(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("待分类")))
    }

    // MARK: Step 2 – files into folders

    func testRelatedFilesShareANewFolderButSingleFilesStayPut() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let first = try f.file("invoice-1.txt")
        let second = try f.file("invoice-2.txt")
        let lonely = try f.file("letter.txt")
        let service = try await f.service()
        var autopilot = f.autopilot(service, planner: f.planner(group: { request in
            let invoices = request.files.filter { $0.name.hasPrefix("invoice") }.map(\.id)
            let letter = request.files.filter { $0.name.hasPrefix("letter") }.map(\.id)
            return ArchiveGroupingResponse(summary: "按用途", groups: [.init(folder: "Finance", fileIDs: invoices, reason: "发票"),
                                                                      .init(folder: "Letters", fileIDs: letter, reason: "信件")])
        }))
        var reported: [ArchiveFileActivity] = []
        autopilot.report = { reported += $0 }
        let summary = try await autopilot.run()
        XCTAssertEqual(summary.movedFiles, 2)
        XCTAssertEqual(summary.createdDirectories, 1)
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Finance/invoice-1.txt")))
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Finance/invoice-2.txt")))
        XCTAssertFalse(ArchiveFileSystem.exists(first))
        XCTAssertFalse(ArchiveFileSystem.exists(second))
        XCTAssertTrue(ArchiveFileSystem.exists(lonely), "A new folder for one file is refused.")
        XCTAssertFalse(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Letters")))
        let records = await service.snapshot().files ?? [:]
        XCTAssertTrue(records.values.allSatisfy { $0.stage == .grouped })
        XCTAssertEqual(records[lonely.path]?.resolution, .unplaced, "A loose file with nowhere to go is not counted as organized.")
        XCTAssertEqual(records[f.workspace.appendingPathComponent("Finance/invoice-1.txt").path]?.resolution, .organized)
        XCTAssertEqual(reported.last { $0.path == first.path }?.detail, "已归入「Finance」")
    }

    func testUnplacedFilesAreReconsideredWhenTheWorkspaceChanges() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let letter = try f.file("letter.txt")
        _ = try f.file("invoice.txt")
        let service = try await f.service()
        var reviews = 0
        var groupings = 0
        let autopilot = f.autopilot(service, planner: f.planner(
            review: { request in
                reviews += 1
                return ArchiveFileDecision(proposedName: request.file.source.lastPathComponent, folder: request.folder)
            },
            group: { _ in
                groupings += 1
                return ArchiveGroupingResponse(summary: nil, groups: [])
            }
        ))
        _ = try await autopilot.run()
        XCTAssertEqual(reviews, 2)
        XCTAssertEqual(groupings, 1)
        _ = try await autopilot.run()
        XCTAssertEqual(groupings, 1, "Nothing changed, so nothing is asked again.")
        XCTAssertEqual(reviews, 2, "Unchanged files are skipped while the folders stay the same.")
        var config = f.config
        config.stableSeconds = 0
        try await service.configure(config)
        let record = await service.snapshot().files?[letter.path]
        XCTAssertNotNil(record, "The record is kept across a change of scope.")
        _ = try await autopilot.run()
        XCTAssertEqual(reviews, 4, "Unplaced files are reviewed again when the scope changes.")
        XCTAssertEqual(groupings, 2)
    }

    func testUnplacedFilesAreReconsideredWhenFoldersChange() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let letter = try f.file("letter.txt")
        let service = try await f.service()
        var reviews = 0
        let autopilot = f.autopilot(service, planner: f.planner(review: { request in
            reviews += 1
            let fits = request.folders.first { $0 == "Letters" }
            return ArchiveFileDecision(proposedName: request.file.source.lastPathComponent, folder: fits ?? request.folder, belongsHere: fits != nil)
        }))
        _ = try await autopilot.run()
        _ = try await autopilot.run()
        XCTAssertEqual(reviews, 1)
        let record = await service.snapshot().files?[letter.path]
        XCTAssertEqual(record?.resolution, .unplaced)
        try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent("Letters"), withIntermediateDirectories: true)
        _ = try await autopilot.run()
        XCTAssertEqual(reviews, 2, "A new folder may be the place an unplaced file was missing.")
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Letters/letter.txt")))
    }

    func testLargeLooseFilesAreStillReviewedAndPlaced() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent("music"), withIntermediateDirectories: true)
        let song = f.workspace.appendingPathComponent("aori - song.mp3")
        try Data(repeating: 7, count: 4_096).write(to: song)
        // Far below the file's size: keywords cannot be read, but the file must still be handled by its name.
        let service = try await f.service(maxFileBytes: 100)
        var keywordsSeen: [String]?
        let summary = try await f.autopilot(service, planner: f.planner(review: { request in
            keywordsSeen = request.file.keywords
            return ArchiveFileDecision(proposedName: request.file.source.lastPathComponent, folder: "music", belongsHere: false)
        })).run()
        XCTAssertEqual(keywordsSeen, ["aori", "song"], "A song is never read; its keywords come from the name alone.")
        XCTAssertEqual(summary.movedFiles, 1)
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("音乐/aori - song.mp3")),
                      "`music` became the canonical `音乐` first; the model's synonym still finds it.")
    }

    func testMisfiledFileLeavesItsFolder() async throws {
        let f = try Fixture()
        defer { f.remove() }
        for name in ["Band", "Finance"] {
            try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("song".utf8).write(to: f.workspace.appendingPathComponent("Band/song.mp3"))
        try Data("invoice".utf8).write(to: f.workspace.appendingPathComponent("Band/invoice.pdf"))
        try Data("report".utf8).write(to: f.workspace.appendingPathComponent("Band/report.pdf"))
        _ = try f.file("notes.pdf")
        let service = try await f.service()
        var siblingsSeen: [String] = []
        let autopilot = f.autopilot(service, planner: f.planner(
            review: { request in
                let name = request.file.source.lastPathComponent
                if name == "invoice.pdf" { siblingsSeen = request.siblings }
                switch name {
                case "invoice.pdf": return ArchiveFileDecision(proposedName: name, folder: "Finance", belongsHere: false)
                case "report.pdf": return ArchiveFileDecision(proposedName: name, folder: request.folder, belongsHere: false)
                default: return ArchiveFileDecision(proposedName: name, folder: request.folder, belongsHere: !request.folder.isEmpty)
                }
            },
            group: { request in
                let pdfs = request.files.filter { $0.name.hasSuffix(".pdf") }.map(\.id)
                return ArchiveGroupingResponse(summary: nil, groups: request.directory.isEmpty ? [.init(folder: "Docs", fileIDs: pdfs, reason: nil)] : [])
            }
        ))
        _ = try await autopilot.run()
        XCTAssertEqual(siblingsSeen.sorted(), ["report.pdf", "song.mp3"])
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Finance/invoice.pdf")), "Moved to the folder that fits.")
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("文档/report.pdf")),
                      "Without a fitting folder it is grouped with the loose files; `Docs` is the dictionary's `文档`.")
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("文档/notes.pdf")))
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Band/song.mp3")))
    }

    // MARK: Step 0 – equivalent folders

    func testEquivalentFoldersAreMergedWithoutOverwriting() async throws {
        let f = try Fixture()
        defer { f.remove() }
        for name in ["音乐", "Downloads/music"] {
            try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("kept".utf8).write(to: f.workspace.appendingPathComponent("音乐/a.mp3"))
        try Data("other".utf8).write(to: f.workspace.appendingPathComponent("Downloads/music/a.mp3"))
        try Data("b".utf8).write(to: f.workspace.appendingPathComponent("Downloads/music/b.mp3"))
        try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent("Downloads/music/live"), withIntermediateDirectories: true)
        try Data("c".utf8).write(to: f.workspace.appendingPathComponent("Downloads/music/live/c.mp3"))
        let service = try await f.service()
        let summary = try await f.autopilot(service, planner: f.planner(audit: { request in
            XCTAssertEqual(request.folders.map(\.path).sorted(), ["Downloads", "Downloads/music", "Downloads/music/live", "音乐"])
            XCTAssertEqual(request.folders.first { $0.path == "Downloads/music" }?.guess, "音乐", "The dictionary's reading is sent along.")
            return ArchiveAuditResponse(folders: [])
        })).run()
        XCTAssertEqual(try String(contentsOf: f.workspace.appendingPathComponent("音乐/a.mp3"), encoding: .utf8), "kept")
        XCTAssertEqual(try String(contentsOf: f.workspace.appendingPathComponent("音乐/a_2.mp3"), encoding: .utf8), "other",
                       "A clash is told apart by the number field, not `a (2).mp3`.")
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("音乐/b.mp3")))
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("音乐/live/c.mp3")))
        XCTAssertFalse(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Downloads/music")), "The emptied folder is removed.")
        XCTAssertEqual(summary.movedDirectories, 1)
        XCTAssertEqual(summary.removedDirectories, 1)

        // Every step is in the history and can be undone.
        let plans = await service.snapshot().ai?.plans ?? []
        for plan in plans.reversed() {
            for operation in plan.files.reversed() where operation.status == .complete { try await service.undo(operation.id) }
            for operation in plan.directories.reversed() where operation.status == .complete {
                try await service.undoAIDirectory(planID: plan.id, operationID: operation.id)
            }
        }
        XCTAssertEqual(try String(contentsOf: f.workspace.appendingPathComponent("Downloads/music/a.mp3"), encoding: .utf8), "other")
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Downloads/music/live/c.mp3")))
    }

    func testNestedSameCategoryFolderIsFlattenedIntoTheCanonicalPath() async throws {
        let f = try Fixture()
        defer { f.remove() }
        for name in ["Music", "Music/Songs"] {
            try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: f.workspace.appendingPathComponent("Music/Songs/x.mp3"))
        let service = try await f.service()
        _ = try await f.autopilot(service, planner: f.planner()).run()
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("音乐/x.mp3")))
        XCTAssertFalse(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Music")))
        XCTAssertFalse(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("音乐/Songs")))
        let isClean = await service.snapshot().consistency?.isClean
        XCTAssertEqual(isClean, true)
    }

    func testGroupingReusesExistingFolderRegardlessOfCase() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent("Finance"), withIntermediateDirectories: true)
        _ = try f.file("invoice.txt")
        let service = try await f.service()
        let autopilot = f.autopilot(service, planner: f.planner(group: { request in
            ArchiveGroupingResponse(summary: nil, groups: [.init(folder: "finance", fileIDs: request.files.map(\.id), reason: nil)])
        }))
        let summary = try await autopilot.run()
        XCTAssertEqual(summary.movedFiles, 1)
        XCTAssertEqual(summary.createdDirectories, 0)
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Finance/invoice.txt")))
    }

    func testUndoKeepsRestoredFileRecorded() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file("invoice-1.txt")
        _ = try f.file("invoice-2.txt")
        let service = try await f.service()
        var groupCalls = 0
        let autopilot = f.autopilot(service, planner: f.planner(group: { request in
            groupCalls += 1
            return ArchiveGroupingResponse(summary: nil, groups: [.init(folder: "Finance", fileIDs: request.files.map(\.id), reason: nil)])
        }))
        let summary = try await autopilot.run()
        let batch = try XCTUnwrap(summary.batchIDs.last)
        let plans = await service.snapshot().ai?.plans ?? []
        let plan = try XCTUnwrap(plans.first { $0.id == batch })
        let moved = try XCTUnwrap(plan.files.first { $0.source == source })
        try await service.undo(moved.id)
        try await service.markSettled([moved.source.path: moved.fingerprint], removing: [moved.destination.path])
        try await service.moveRecords(from: moved.destination.path, to: moved.source.path)
        _ = try await autopilot.run()
        XCTAssertEqual(groupCalls, 1, "A file the user restored must not be organized again.")
        XCTAssertTrue(ArchiveFileSystem.exists(source))
    }

    // MARK: Step 3 – folder levels

    func testRelatedFoldersMoveUnderANewLevelAndCanBeUndone() async throws {
        let f = try Fixture()
        defer { f.remove() }
        for name in ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "f.txt"] { _ = try f.file(name) }
        let service = try await f.service()
        var nestCalls = 0
        let autopilot = f.autopilot(service, planner: f.planner(
            group: { request in
                let ids = request.files.sorted { $0.name < $1.name }.map(\.id)
                return ArchiveGroupingResponse(summary: nil, groups: [
                    .init(folder: "Invoices", fileIDs: Array(ids[0..<2]), reason: nil),
                    .init(folder: "Receipts", fileIDs: Array(ids[2..<4]), reason: nil),
                    .init(folder: "Letters", fileIDs: Array(ids[4..<6]), reason: nil),
                ])
            },
            nest: { request in
                nestCalls += 1
                guard request.folders.map(\.name).contains("Invoices") else { return ArchiveNestingResponse(summary: nil, groups: [], renames: []) }
                return ArchiveNestingResponse(summary: "财务", groups: [.init(folder: "Finance", children: ["Invoices", "receipts"], reason: "都是财务票据")],
                                              renames: [])
            }
        ))
        let summary = try await autopilot.run()
        XCTAssertEqual(summary.movedDirectories, 2)
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Finance/Invoices/a.txt")))
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Finance/Receipts/c.txt")))
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Letters/e.txt")))
        let records = await service.snapshot().files ?? [:]
        XCTAssertNotNil(records[f.workspace.appendingPathComponent("Finance/Invoices/a.txt").path], "Records move with their folder.")
        XCTAssertGreaterThanOrEqual(nestCalls, 1)

        let batch = try XCTUnwrap(summary.batchIDs.last)
        let plans = await service.snapshot().ai?.plans ?? []
        let plan = try XCTUnwrap(plans.first { $0.id == batch })
        for operation in plan.directories.reversed() where operation.status == .complete {
            try await service.undoAIDirectory(planID: plan.id, operationID: operation.id)
        }
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Invoices/a.txt")))
        XCTAssertFalse(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("Finance")))
        let restored = await service.snapshot().files ?? [:]
        XCTAssertNotNil(restored[f.workspace.appendingPathComponent("Invoices/a.txt").path], "Undo moves the records back too.")
    }

    func testFolderLevelThatWrapsEverythingIsRefused() async throws {
        let f = try Fixture()
        defer { f.remove() }
        for name in ["Invoices", "Receipts", "Taxes"] {
            try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in ["a.txt", "b.txt"] { _ = try f.file(name) }
        let service = try await f.service()
        let autopilot = f.autopilot(service, planner: f.planner(
            group: { request in ArchiveGroupingResponse(summary: nil, groups: [.init(folder: "Notes", fileIDs: request.files.map(\.id), reason: nil)]) },
            nest: { request in
                ArchiveNestingResponse(summary: nil, groups: [.init(folder: "All", children: request.folders.map(\.name), reason: nil)], renames: [])
            }
        ))
        let summary = try await autopilot.run()
        XCTAssertEqual(summary.movedDirectories, 0)
        XCTAssertFalse(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("All")))
    }

    // MARK: Offline rules and reporting

    func testFilesAreReviewedInBatchesAndAppliedOneByOne() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent("Taxes"), withIntermediateDirectories: true)
        for name in ["a.pdf", "b.pdf", "c.pdf", "d.pdf", "e.pdf"] { _ = try f.file(name) }
        let service = try await f.service()
        var batches: [[String]] = []
        var autopilot = ArchiveAutopilot(service: service, planner: ArchiveStagePlanner(
            audit: { _ in ArchiveAuditResponse(folders: []) },
            review: { batch in
                batches.append(batch.files.map { $0.file.source.lastPathComponent })
                XCTAssertEqual(batch.folders, ["Taxes"])
                var decisions: [String: ArchiveFileDecision] = [:]
                for review in batch.files {
                    decisions[review.file.id] = ArchiveFileDecision(proposedName: review.file.source.lastPathComponent, topic: "税务",
                                                                    folder: "Taxes", belongsHere: false, reason: "税单", summary: "一份税务文件")
                }
                return decisions
            },
            group: { _ in ArchiveGroupingResponse(summary: nil, groups: []) },
            nest: { _ in ArchiveNestingResponse(summary: nil, groups: [], renames: []) }
        ))
        autopilot.stableWait = .milliseconds(10)
        autopilot.reviewBatch = 2
        let summary = try await autopilot.run()
        XCTAssertEqual(batches.map(\.count), [2, 2, 1])
        XCTAssertEqual(summary.movedFiles, 5)
        let files = await service.snapshot().files
        let record = try XCTUnwrap(files?[f.workspace.appendingPathComponent("Taxes/a.pdf").path])
        XCTAssertEqual(record.summary, "一份税务文件")
        XCTAssertEqual(record.previousFolder, "")
        XCTAssertNotNil(record.createdSeconds)
        XCTAssertNotNil(record.operationID)
        let operations = await service.snapshot().operations
        XCTAssertTrue(operations.contains { $0.id == record.operationID && $0.status == .complete })
    }

    func testUnusableBatchAnswerIsSplitUntilTheConfusingFileIsIsolated() async throws {
        let f = try Fixture()
        defer { f.remove() }
        for name in ["one.txt", "two.txt", "three.txt", "four.txt"] { _ = try f.file(name) }
        let service = try await f.service()
        var asked: [[String]] = []
        var autopilot = f.autopilot(service, planner: ArchiveStagePlanner(
            audit: { _ in ArchiveAuditResponse(folders: []) },
            review: { batch in
                let names = batch.files.map { $0.file.source.lastPathComponent }
                asked.append(names)
                // Any batch containing the troublesome file comes back garbled.
                if names.contains("three.txt") { throw ArchiveError("无效") }
                var decisions: [String: ArchiveFileDecision] = [:]
                for review in batch.files {
                    decisions[review.file.id] = ArchiveFileDecision(proposedName: "ok-" + review.file.source.lastPathComponent, folder: review.folder)
                }
                return decisions
            },
            group: { _ in ArchiveGroupingResponse(summary: nil, groups: []) },
            nest: { _ in ArchiveNestingResponse(summary: nil, groups: [], renames: []) }
        ))
        autopilot.reviewBatch = 4
        let summary = try await autopilot.run()
        XCTAssertEqual(summary.renamedFiles, 3)
        XCTAssertEqual(summary.movedFiles, 1)
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("待分类/three.txt")),
                      "The isolated file is collected with other files nobody could identify.")
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("ok-one.txt")))
        XCTAssertEqual(asked.filter { $0 == ["three.txt"] }.count, 2, "A single file gets a second chance before being left alone.")
        let record = await service.snapshot().files?[f.workspace.appendingPathComponent("待分类/three.txt").path]
        XCTAssertEqual(record?.resolution, .unplaced)
    }

    func testTakenDestinationNameGetsANumberField() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent("图片"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: f.workspace.appendingPathComponent("图片/a.jpg"))
        let clash = try f.file("a.jpg")
        let service = try await f.service()
        let summary = try await f.autopilot(service, planner: f.planner(review: { request in
            ArchiveFileDecision(proposedName: request.file.source.lastPathComponent, folder: "图片", belongsHere: false)
        })).run()
        XCTAssertEqual(summary.movedFiles, 1)
        XCTAssertFalse(ArchiveFileSystem.exists(clash))
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("图片/a_2.jpg")))
        XCTAssertEqual(try String(contentsOf: f.workspace.appendingPathComponent("图片/a.jpg"), encoding: .utf8), "old")
    }

    func testReportsPerFileStatusThroughEachStep() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file("scan.txt")
        let service = try await f.service()
        var autopilot = f.autopilot(service, planner: f.planner(review: { request in
            ArchiveFileDecision(proposedName: "收据.txt", topic: "收据", folder: request.folder)
        }))
        var reported: [ArchiveFileActivity] = []
        autopilot.report = { reported += $0 }
        _ = try await autopilot.run()
        XCTAssertEqual(reported.first?.status, .queued)
        XCTAssertTrue(reported.contains { $0.path == source.path && $0.status == .processing })
        XCTAssertEqual(reported.first { $0.path == source.path && $0.status == .completed }?.detail, "已改名为 收据.txt · 收据")
    }

    func testWorkspaceConfigurationValidates() throws {
        let f = try Fixture()
        defer { f.remove() }
        XCTAssertNoThrow(try ArchiveFileSystem.validateConfiguration(f.config, stateDirectory: f.state))
        var nested = f.config
        nested.folders.append(ArchiveFolder(role: .library, url: f.workspace.appendingPathComponent("Inside")))
        XCTAssertThrowsError(try ArchiveFileSystem.validateConfiguration(nested, stateDirectory: f.state, requiresDirectoryAccess: false))
    }

    // MARK: Files sorted by type

    func testSongsAndInstallersAreSortedByTypeWithoutTheModel() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent("Library/Music"), withIntermediateDirectories: true)
        let kept = f.workspace.appendingPathComponent("Library/Music/kept.flac")
        try Data("kept".utf8).write(to: kept)
        _ = try f.file("loose song.mp3")
        _ = try f.file("Setup 1.2.dmg")
        _ = try f.file("notes.txt")
        let service = try await f.service()
        var asked: [String] = []
        var autopilot = f.autopilot(service, planner: f.planner(review: { request in
            asked.append(request.file.source.lastPathComponent)
            return ArchiveFileDecision(proposedName: request.file.source.lastPathComponent, folder: request.folder)
        }))
        autopilot.sortsByType = true
        let summary = try await autopilot.run()
        XCTAssertEqual(asked, ["notes.txt"], "Only files the model can say something about are sent.")
        let home = f.workspace.appendingPathComponent("音乐/kept.flac")
        XCTAssertFalse(ArchiveFileSystem.exists(kept))
        XCTAssertTrue(ArchiveFileSystem.exists(home), "`Library/Music` was moved to the canonical `音乐` before files were placed.")
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("音乐/loose song.mp3")),
                      "A loose song joins the one music folder.")
        let installer = f.workspace.appendingPathComponent("安装包与镜像/Setup_1.2.dmg")
        XCTAssertTrue(ArchiveFileSystem.exists(installer), "Moved and named to the template, version kept.")
        XCTAssertEqual(summary.movedFiles, 2)
        let records = await service.snapshot().files ?? [:]
        XCTAssertEqual(records[home.path]?.resolution, .organized)
        XCTAssertEqual(records[installer.path]?.previousFolder, "")
    }

    func testFairOrderLetsEveryFolderTakeTurns() {
        func evidence(_ path: String) -> ArchiveEvidence {
            ArchiveEvidence(url: URL(fileURLWithPath: path), fingerprint: ArchiveFingerprint(device: 0, inode: 0, size: 0, modifiedSeconds: 0,
                                                                                            modifiedNanoseconds: 0, sha256: ""),
                            words: [], extractionNote: nil)
        }
        let files = ["/w/A/Music/1.mp3", "/w/A/Music/2.mp3", "/w/A/Music/3.mp3", "/w/Docs/a.pdf", "/w/Docs/b.pdf", "/w/x.txt"].map(evidence)
        let order = ArchiveService.fairOrder(files, known: ["/w/Docs/a.pdf"]).map(\.url.path)
        XCTAssertEqual(order, ["/w/A/Music/1.mp3", "/w/Docs/b.pdf", "/w/x.txt", "/w/A/Music/2.mp3", "/w/A/Music/3.mp3", "/w/Docs/a.pdf"])
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
            try Data("invoice accounting payable \(name)".utf8).write(to: url)
            return url
        }

        func service(maxFileBytes: Int? = nil) async throws -> ArchiveService {
            let service = try ArchiveService(directory: state)
            var config = self.config
            config.stableSeconds = 0
            if let maxFileBytes { config.maxFileBytes = maxFileBytes }
            try await service.configure(config)
            return service
        }

        /// Keeps every file where it is, groups nothing and adds no levels unless a step is given.
        func planner(audit: (@MainActor (ArchiveAuditRequest) async throws -> ArchiveAuditResponse)? = nil,
                     review: (@MainActor (ArchiveFileReview) async throws -> ArchiveFileDecision)? = nil,
                     group: (@MainActor (ArchiveGroupingRequest) async throws -> ArchiveGroupingResponse)? = nil,
                     nest: (@MainActor (ArchiveNestingRequest) async throws -> ArchiveNestingResponse)? = nil) -> ArchiveStagePlanner {
            let perFile = review ?? { request in
                ArchiveFileDecision(proposedName: request.file.source.lastPathComponent, folder: request.folder)
            }
            return ArchiveStagePlanner(
                audit: audit ?? { _ in ArchiveAuditResponse(folders: []) },
                review: { batch in
                    var decisions: [String: ArchiveFileDecision] = [:]
                    for request in batch.files { decisions[request.file.id] = try await perFile(request) }
                    return decisions
                },
                group: group ?? { _ in ArchiveGroupingResponse(summary: nil, groups: []) },
                nest: nest ?? { _ in ArchiveNestingResponse(summary: nil, groups: [], renames: []) }
            )
        }

        func autopilot(_ service: ArchiveService, planner: ArchiveStagePlanner) -> ArchiveAutopilot {
            var autopilot = ArchiveAutopilot(service: service, planner: planner)
            autopilot.stableWait = .milliseconds(10)
            return autopilot
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
