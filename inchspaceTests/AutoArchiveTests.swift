import Compression
import Darwin
import Foundation
import XCTest
@testable import inchspace

@MainActor
final class AutoArchiveTests: XCTestCase {
    func testLearnObserveSuggestPreviewApplyAndUndo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try ArchiveService(directory: fixture.stateDirectory)
        try await prepare(service, fixture: fixture)
        let learned = await service.snapshot()
        let report = try XCTUnwrap(learned.report)
        XCTAssertEqual(report.sampled, 10)
        XCTAssertGreaterThan(report.heldOut, 0)
        XCTAssertEqual(learned.rules.count, 2)
        XCTAssertTrue(learned.rules.allSatisfy { $0.evidence.count >= 3 })

        let source = try fixture.write("invoice  2026-10-19 INV-0042.txt.txt", in: fixture.inbox,
                                       text: "invoice accounting payable")
        let original = try Data(contentsOf: source)
        let fingerprint = try ArchiveFileSystem.fingerprint(source, maxBytes: fixture.configuration.maxFileBytes)
        let now = Date()
        _ = try await service.suggest(now: now)
        let observed = await service.snapshot()
        XCTAssertTrue(observed.suggestions.isEmpty)
        XCTAssertEqual(observed.observations[source.path]?.fingerprint, fingerprint)
        XCTAssertEqual(observed.observations[source.path]?.firstSeen, now)

        _ = try await service.suggest(now: now.addingTimeInterval(1.999))
        let unstable = await service.snapshot()
        XCTAssertTrue(unstable.suggestions.isEmpty)
        _ = try await service.suggest(now: now.addingTimeInterval(2))
        let suggested = await service.snapshot()
        let suggestion = try XCTUnwrap(suggested.suggestions.first)
        XCTAssertEqual(suggested.suggestions.count, 1)
        XCTAssertTrue(suggestion.executable)
        XCTAssertEqual(suggestion.directory, fixture.invoices)
        XCTAssertEqual(suggestion.proposedName, "invoice 2026-10-19 INV-0042.txt")
        XCTAssertEqual(suggestion.version, learned.version)

        let beforePreview = try fixture.fileContents()
        let stateBeforePreview = try encoded(suggested)
        let plans = try await service.preview([suggestion.id], mode: .both)
        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plan.source, source)
        XCTAssertEqual(plan.destination, fixture.invoices.appendingPathComponent(suggestion.proposedName))
        XCTAssertEqual(plan.fingerprint, fingerprint)
        XCTAssertEqual(plan.status, .planned)
        XCTAssertFalse(ArchiveFileSystem.exists(plan.staging))
        XCTAssertFalse(ArchiveFileSystem.exists(plan.undoStaging))
        let afterPreview = await service.snapshot()
        XCTAssertEqual(try encoded(afterPreview), stateBeforePreview)
        XCTAssertEqual(try fixture.fileContents(), beforePreview, "Preview must not change files or the saved journal.")

        let applied = try await service.apply([suggestion.id], mode: .both)
        let operation = try XCTUnwrap(applied.first)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(operation.status, .complete)
        XCTAssertFalse(ArchiveFileSystem.exists(source))
        XCTAssertEqual(try Data(contentsOf: operation.destination), original)
        XCTAssertEqual(try ArchiveFileSystem.fingerprint(operation.destination, maxBytes: fixture.configuration.maxFileBytes), fingerprint)
        XCTAssertFalse(ArchiveFileSystem.exists(operation.staging))
        let completed = await service.snapshot()
        XCTAssertEqual(completed.suggestions.first?.status, .applied)
        XCTAssertEqual(completed.operations.count, 1)

        try await service.undo(operation.id)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(ArchiveFileSystem.exists(operation.destination))
        XCTAssertFalse(ArchiveFileSystem.exists(operation.undoStaging))
        let undone = await service.snapshot()
        XCTAssertEqual(undone.operations.first?.status, .undone)
        XCTAssertEqual(undone.suggestions.first?.status, .skipped)
        _ = try await service.suggest(now: now.addingTimeInterval(4))
        let rescanned = await service.snapshot()
        XCTAssertEqual(rescanned.suggestions.count, 1, "Undo must not immediately offer the accepted file again.")
    }

    func testMoveOnlyApplyAndUndoPreserveTheOriginalFilename() async throws {
        try await assertModeRoundTrip(.move)
    }

    func testRenameOnlyApplyAndUndoPreserveTheOriginalDirectory() async throws {
        try await assertModeRoundTrip(.rename)
    }

    func testUndoRefusesAnOccupiedOriginalPathAndPreservesBothFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try ArchiveService(directory: fixture.stateDirectory)
        try await prepare(service, fixture: fixture)
        let source = try fixture.write("invoice-current.txt", in: fixture.inbox, text: "invoice accounting payable")
        let suggestion = try await stableSuggestion(service, source: source)
        let applied = try await service.apply([suggestion.id], mode: .both)
        let operation = try XCTUnwrap(applied.first)
        XCTAssertEqual(operation.status, .complete)
        _ = try fixture.write(source.lastPathComponent, in: fixture.inbox, text: "new occupant of original path")
        let before = try fixture.fileContents()
        let beforeState = await service.snapshot()

        await assertRejected(containing: "目标已存在") {
            try await service.undo(operation.id)
        }
        XCTAssertEqual(try fixture.fileContents(), before)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "new occupant of original path")
        XCTAssertEqual(try String(contentsOf: operation.destination, encoding: .utf8), "invoice accounting payable")
        let afterState = await service.snapshot()
        XCTAssertEqual(try encoded(afterState), try encoded(beforeState))
        XCTAssertEqual(afterState.operations.first?.status, .complete)
        XCTAssertFalse(ArchiveFileSystem.exists(operation.undoStaging))
    }

    func testUndoRefusesModifiedArchiveContentAndPreservesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try ArchiveService(directory: fixture.stateDirectory)
        try await prepare(service, fixture: fixture)
        let source = try fixture.write("invoice-current.txt", in: fixture.inbox, text: "invoice accounting payable")
        let suggestion = try await stableSuggestion(service, source: source)
        let applied = try await service.apply([suggestion.id], mode: .both)
        let operation = try XCTUnwrap(applied.first)
        XCTAssertEqual(operation.status, .complete)
        try Data("edited archive content must survive".utf8).write(to: operation.destination)
        let before = try fixture.fileContents()
        let beforeState = await service.snapshot()

        await assertRejected(containing: "源文件已变化") {
            try await service.undo(operation.id)
        }
        XCTAssertEqual(try fixture.fileContents(), before)
        XCTAssertEqual(try String(contentsOf: operation.destination, encoding: .utf8), "edited archive content must survive")
        XCTAssertFalse(ArchiveFileSystem.exists(source))
        XCTAssertFalse(ArchiveFileSystem.exists(operation.undoStaging))
        let afterState = await service.snapshot()
        XCTAssertEqual(try encoded(afterState), try encoded(beforeState))
        XCTAssertEqual(afterState.operations.first?.status, .complete)
    }

    func testBatchValidatesEverySourceBeforeMovingTheFirstValidSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try ArchiveService(directory: fixture.stateDirectory)
        try await prepare(service, fixture: fixture)
        let firstSource = try fixture.write("invoice-first.txt", in: fixture.inbox, text: "invoice accounting payable first")
        let secondSource = try fixture.write("invoice-second.txt", in: fixture.inbox, text: "invoice accounting payable second")
        let now = Date().addingTimeInterval(-3)
        _ = try await service.suggest(now: now)
        _ = try await service.suggest(now: now.addingTimeInterval(2))
        let state = await service.snapshot()
        let selections = state.suggestions.sorted { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(selections.count, 2)
        XCTAssertTrue(selections.allSatisfy(\.executable))
        let valid = try XCTUnwrap(selections.first)
        let changed = try XCTUnwrap(selections.last)
        XCTAssertNotEqual(valid.id, changed.id)
        // The service sorts selected UUIDs. Change the last source so a sequential mutate-then-validate
        // implementation would incorrectly move the earlier, still-valid selection first.
        try Data("invoice changed after the batch was selected".utf8).write(to: changed.source)
        let before = try fixture.fileContents()
        await assertRejected(containing: "源文件已变化") {
            _ = try await service.apply(Set(selections.map(\.id)), mode: .both)
        }
        XCTAssertEqual(try fixture.fileContents(), before)
        XCTAssertTrue(ArchiveFileSystem.exists(firstSource))
        XCTAssertTrue(ArchiveFileSystem.exists(secondSource))
        XCTAssertFalse(ArchiveFileSystem.exists(fixture.invoices.appendingPathComponent(valid.proposedName)))
        let rejected = await service.snapshot()
        XCTAssertEqual(try encoded(rejected), try encoded(state))
        XCTAssertTrue(rejected.operations.isEmpty)
    }

    func testChangedSourceRejectsPreviewAndApplyWithoutMovingAnything() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try ArchiveService(directory: fixture.stateDirectory)
        try await prepare(service, fixture: fixture)
        let source = try fixture.write("invoice-current.txt", in: fixture.inbox, text: "invoice accounting payable")
        let suggestion = try await stableSuggestion(service, source: source)
        try Data("invoice accounting payable changed after suggestion".utf8).write(to: source)
        let before = try fixture.fileContents()

        await assertRejected(containing: "源文件已变化") {
            _ = try await service.preview([suggestion.id], mode: .both)
        }
        await assertRejected(containing: "源文件已变化") {
            _ = try await service.apply([suggestion.id], mode: .both)
        }
        XCTAssertEqual(try fixture.fileContents(), before)
        let state = await service.snapshot()
        XCTAssertTrue(state.operations.isEmpty)
        XCTAssertEqual(state.suggestions.first?.status, .pending)
    }

    func testChangedLearningEvidenceRejectsAnOtherwiseUnchangedSuggestion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try ArchiveService(directory: fixture.stateDirectory)
        try await prepare(service, fixture: fixture)
        let source = try fixture.write("invoice-current.txt", in: fixture.inbox, text: "invoice accounting payable")
        let suggestion = try await stableSuggestion(service, source: source)
        let learned = await service.snapshot()
        let rule = try XCTUnwrap(learned.rules.first { $0.directory == fixture.invoices })
        let evidence = try XCTUnwrap(rule.evidence.first)
        try Data("changed training evidence".utf8).write(to: evidence.url)
        let before = try fixture.fileContents()

        await assertRejected(containing: "历史样本已变化") {
            _ = try await service.preview([suggestion.id], mode: .both)
        }
        await assertRejected(containing: "历史样本已变化") {
            _ = try await service.apply([suggestion.id], mode: .both)
        }
        XCTAssertEqual(try fixture.fileContents(), before)
        XCTAssertEqual(try ArchiveFileSystem.fingerprint(source, maxBytes: fixture.configuration.maxFileBytes), suggestion.fingerprint)
        let state = await service.snapshot()
        XCTAssertTrue(state.operations.isEmpty)
    }

    func testExactCaseAndCanonicalUnicodeTargetCollisionsNeverOverwrite() async throws {
        let names = [
            (source: "invoice.txt", occupied: "invoice.txt"),
            (source: "invoice.txt", occupied: "INVOICE.TXT"),
            (source: "café invoice.txt", occupied: "cafe\u{301} invoice.txt"),
        ]
        for names in names {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let service = try ArchiveService(directory: fixture.stateDirectory)
            try await prepare(service, fixture: fixture)
            let source = try fixture.write(names.source, in: fixture.inbox, text: "invoice accounting payable")
            let suggestion = try await stableSuggestion(service, source: source)
            // Add the collision after learning so it is not itself part of the evidence.
            let occupied = try fixture.write(names.occupied, in: fixture.invoices, text: "existing target must survive")
            let before = try fixture.fileContents()
            XCTAssertEqual(ArchiveFileSystem.nameKey(names.source), ArchiveFileSystem.nameKey(names.occupied))

            await assertRejected(containing: "目标已存在") {
                _ = try await service.preview([suggestion.id], mode: .both)
            }
            await assertRejected(containing: "目标已存在") {
                _ = try await service.apply([suggestion.id], mode: .both)
            }
            XCTAssertEqual(try fixture.fileContents(), before)
            XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "existing target must survive")
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "invoice accounting payable")
            let state = await service.snapshot()
            XCTAssertTrue(state.operations.isEmpty)
        }
    }

    func testBatchWithCollidingNormalizedDestinationsIsRejectedBeforeAnyMove() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try ArchiveService(directory: fixture.stateDirectory)
        try await prepare(service, fixture: fixture)
        _ = try fixture.write("invoice  report.txt", in: fixture.inbox, text: "invoice accounting payable first")
        _ = try fixture.write("invoice report.txt", in: fixture.inbox, text: "invoice accounting payable second")
        let now = Date().addingTimeInterval(-3)
        _ = try await service.suggest(now: now)
        _ = try await service.suggest(now: now.addingTimeInterval(2))
        let state = await service.snapshot()
        XCTAssertEqual(state.suggestions.count, 2)
        XCTAssertTrue(state.suggestions.allSatisfy(\.executable))
        let ids = Set(state.suggestions.map(\.id))
        let before = try fixture.fileContents()

        await assertRejected(containing: "同一位置") {
            _ = try await service.apply(ids, mode: .both)
        }
        XCTAssertEqual(try fixture.fileContents(), before)
        let rejected = await service.snapshot()
        XCTAssertTrue(rejected.operations.isEmpty)
    }

    func testExpiredSuggestionRejectsApplyAndBecomesStaleOnRescan() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try ArchiveService(directory: fixture.stateDirectory)
        try await prepare(service, fixture: fixture)
        let source = try fixture.write("invoice-current.txt", in: fixture.inbox, text: "invoice accounting payable")
        let past = Date().addingTimeInterval(-86_410)
        let suggestion = try await stableSuggestion(service, source: source, firstSeen: past)
        let before = try fixture.fileContents()
        await assertRejected(containing: "建议已过期") {
            _ = try await service.apply([suggestion.id], mode: .both)
        }
        XCTAssertEqual(try fixture.fileContents(), before)

        _ = try await service.suggest(now: Date())
        let refreshed = await service.snapshot()
        XCTAssertEqual(refreshed.suggestions.first { $0.id == suggestion.id }?.status, .stale)
        XCTAssertEqual(refreshed.suggestions.filter { $0.source == source && $0.status == .pending }.count, 1)
        XCTAssertTrue(refreshed.operations.isEmpty)
    }

    func testLearningAndConfigurationChangesInvalidateOldVersions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try ArchiveService(directory: fixture.stateDirectory)
        try await prepare(service, fixture: fixture)
        let source = try fixture.write("invoice-current.txt", in: fixture.inbox, text: "invoice accounting payable")
        let original = try await stableSuggestion(service, source: source)
        _ = try await service.learn()
        let relearned = await service.snapshot()
        XCTAssertGreaterThan(relearned.version, original.version)
        XCTAssertEqual(relearned.suggestions.first { $0.id == original.id }?.status, .stale)
        XCTAssertEqual(relearned.report?.cached, 10)
        await assertRejected(containing: "规则已更新") {
            _ = try await service.apply([original.id], mode: .both)
        }

        let renewed = try await stableSuggestion(service, source: source)
        XCTAssertEqual(renewed.version, relearned.version)
        try await service.configure(fixture.configuration)
        let reconfigured = await service.snapshot()
        XCTAssertGreaterThan(reconfigured.version, renewed.version)
        XCTAssertEqual(reconfigured.suggestions.first { $0.id == renewed.id }?.status, .stale)
        XCTAssertTrue(reconfigured.rules.isEmpty)
        XCTAssertTrue(reconfigured.observations.isEmpty)
        XCTAssertTrue(reconfigured.cache.isEmpty)
        XCTAssertNil(reconfigured.report)
        await assertRejected(containing: "规则已更新") {
            _ = try await service.preview([renewed.id], mode: .both)
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "invoice accounting payable")
        XCTAssertTrue(reconfigured.operations.isEmpty)
    }

    func testScanSkipsExclusionsRepositoriesSymlinksPackagesHiddenAndTemporaryFiles() async throws {
        let fixture = try Fixture(training: false)
        defer { fixture.remove() }
        var configuration = fixture.configuration
        let outside = try fixture.directory("Outside")
        let outsideFile = try fixture.write("outside.txt", in: outside, text: "synthetic external sentinel")

        for (root, role) in [(fixture.inbox, ArchiveFolderRole.inbox), (fixture.library, .library)] {
            let allowed = try fixture.write("allowed.txt", in: root, text: "allowed file")
            let excluded = try fixture.directory("Excluded", in: root)
            _ = try fixture.write("excluded.txt", in: excluded, text: "excluded sentinel")
            configuration.folders.append(ArchiveFolder(role: .excluded, url: excluded, bookmark: nil))
            for marker in [".git", ".hg", ".svn"] {
                let repository = try fixture.directory("Repository-\(marker.dropFirst())", in: root)
                _ = try fixture.directory(marker, in: repository)
                _ = try fixture.write("repository.txt", in: repository, text: "repository sentinel")
            }
            let hidden = try fixture.directory(".hidden", in: root)
            _ = try fixture.write("hidden-child.txt", in: hidden, text: "hidden sentinel")
            _ = try fixture.write(".hidden.txt", in: root, text: "hidden file sentinel")
            let package = try fixture.directory("Example.app", in: root)
            _ = try fixture.write("package.txt", in: package, text: "package sentinel")
            for ext in ["part", "CRDOWNLOAD", "download", "tmp", "swp"] {
                _ = try fixture.write("unfinished.\(ext)", in: root, text: "temporary sentinel")
            }
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file-link.txt"), withDestinationURL: outsideFile)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("directory-link"), withDestinationURL: outside)
            let scan = try ArchiveFileSystem.scan(configuration, role: role)
            XCTAssertEqual(scan.files.map(\.url), [allowed])
            XCTAssertTrue(scan.warnings.contains { $0.contains("排除") })
            XCTAssertTrue(scan.warnings.contains { $0.contains("代码仓库") })
            XCTAssertTrue(scan.warnings.contains { $0.contains("符号链接") })
        }
        XCTAssertEqual(try String(contentsOf: outsideFile, encoding: .utf8), "synthetic external sentinel")
        try ArchiveFileSystem.validateConfiguration(configuration, stateDirectory: fixture.stateDirectory)
    }

    func testTwoSampleCategoriesAlwaysKeepTheirTrainingEvidence() async throws {
        let fixture = try Fixture(training: false)
        defer { fixture.remove() }
        let categories = ["Alpha", "Beta", "Delta", "Epsilon", "Gamma"]
        for name in categories {
            let folder = try fixture.directory(name, in: fixture.library)
            for index in 1...2 {
                _ = try fixture.write("\(name)-\(index).txt", in: folder, text: "\(name) businessrecord")
            }
        }
        let service = try ArchiveService(directory: fixture.stateDirectory)
        try await prepare(service, fixture: fixture)
        let learned = await service.snapshot()
        XCTAssertEqual(learned.rules.count, categories.count)
        XCTAssertTrue(learned.rules.allSatisfy { $0.evidence.count == 2 })
        XCTAssertEqual(learned.report?.heldOut, 0)
        let source = try fixture.write("epsilon-current.txt", in: fixture.inbox, text: "epsilon businessrecord")
        let suggestion = try await stableSuggestion(service, source: source)
        XCTAssertEqual(suggestion.directory?.lastPathComponent, "Epsilon")
    }

    func testBrokenBookmarksCanBeRemovedIndividuallyAndReauthorized() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let second = try fixture.directory("SecondInbox")
        var saved = ArchiveState()
        saved.configuration = fixture.configuration
        saved.configuration.folders[0].bookmark = Data("broken-first-bookmark".utf8)
        saved.configuration.folders.append(ArchiveFolder(role: .inbox, url: second,
                                                         bookmark: Data("broken-second-bookmark".utf8)))
        try save(saved, directory: fixture.stateDirectory)
        let service = try ArchiveService(directory: fixture.stateDirectory)
        var repaired = saved.configuration
        repaired.folders.removeAll { $0.url == fixture.inbox }
        try await service.configure(repaired)
        let firstRemoval = await service.snapshot()
        XCTAssertEqual(firstRemoval.configuration.folders.count, 2)
        repaired.folders.removeAll { $0.url == second }
        try await service.configure(repaired)
        repaired.folders.append(ArchiveFolder(role: .inbox, url: fixture.inbox, bookmark: nil))
        try await service.configure(repaired)
        _ = try await service.learn()
        let learned = await service.snapshot()
        XCTAssertEqual(learned.rules.count, 2)
        XCTAssertEqual(learned.report?.sampled, 10)
    }

    func testNormalizedNamesAreIdempotentAndPreserveDatesBusinessIdentifiersAndExtensions() async throws {
        let examples: [(String, String)] = [
            ("  invoice   report.txt.txt  ", "invoice report.txt"),
            ("report.TXT.txt", "report.txt"),
            ("report.txt .txt", "report.txt"),
            ("report.txt. .TXT", "report.TXT"),
            ("a/b:c\\d\u{0001}.txt", "a_b_c_d_.txt"),
            ("cafe\u{301} invoice.txt", "café invoice.txt"),
            ("...", "untitled"),
            ("2026-10-19 INV-0042 00123456789 合同.txt", "2026-10-19 INV-0042 00123456789 合同.txt"),
            ("2026.10.19 PO-00001234 v2.1.csv", "2026.10.19 PO-00001234 v2.1.csv"),
        ]
        for (input, expected) in examples {
            let normalized = try ArchiveFileSystem.normalizedName(input)
            XCTAssertEqual(normalized, expected, input)
            XCTAssertEqual(try ArchiveFileSystem.normalizedName(normalized), normalized, input)
        }
    }

    func testNormalizedNamesRespectUTF8ByteAndExtensionBounds() async throws {
        for stem in [String(repeating: "界", count: 120), String(repeating: "👩🏽‍💻", count: 50)] {
            let normalized = try ArchiveFileSystem.normalizedName(stem + ".txt")
            XCTAssertLessThanOrEqual(normalized.utf8.count, 240)
            XCTAssertEqual((normalized as NSString).pathExtension, "txt")
            XCTAssertTrue(stem.hasPrefix(String(normalized.dropLast(4))))
            XCTAssertEqual(try ArchiveFileSystem.normalizedName(normalized), normalized)
            XCTAssertEqual(String(data: Data(normalized.utf8), encoding: .utf8), normalized)
        }
        for ext in [String(repeating: "x", count: 39), String(repeating: "界", count: 13)] {
            let input = "invoice." + ext
            XCTAssertEqual(try ArchiveFileSystem.normalizedName(input), input, "The dot plus extension may occupy exactly 40 UTF-8 bytes.")
        }
        for ext in [String(repeating: "x", count: 40), String(repeating: "界", count: 14)] {
            XCTAssertThrowsError(try ArchiveFileSystem.normalizedName("invoice." + ext)) { error in
                XCTAssertTrue(error.localizedDescription.contains("扩展名过长"))
            }
        }
    }

    func testAmbiguousInsufficientAndUnmatchedEvidenceProduceDistinctNonExecutableSuggestions() async throws {
        let fixture = try Fixture(training: false)
        defer { fixture.remove() }
        for name in ["Alpha", "Beta"] {
            let category = try fixture.directory(name, in: fixture.library)
            for index in 1...5 {
                _ = try fixture.write("\(name)-\(index).txt", in: category, text: "sharedtopic")
            }
        }
        // This class deliberately has one sample to exercise insufficient evidence.
        let sparse = try fixture.directory("Sparse", in: fixture.library)
        _ = try fixture.write("sparse-history.txt", in: sparse, text: "raretopic")
        let ambiguous = try fixture.write("sharedtopic.txt", in: fixture.inbox, text: "sharedtopic")
        let insufficient = try fixture.write("sparse-current.txt", in: fixture.inbox, text: "raretopic")
        let unmatched = try fixture.write("unmatched.txt", in: fixture.inbox, text: "unrelatedconcept")
        let service = try ArchiveService(directory: fixture.stateDirectory)
        try await prepare(service, fixture: fixture)
        let now = Date().addingTimeInterval(-3)
        _ = try await service.suggest(now: now)
        _ = try await service.suggest(now: now.addingTimeInterval(2))
        let state = await service.snapshot()
        XCTAssertEqual(state.suggestions.count, 3)
        let ambiguousSuggestion = try XCTUnwrap(state.suggestions.first { $0.source == ambiguous })
        XCTAssertNil(ambiguousSuggestion.directory)
        XCTAssertFalse(ambiguousSuggestion.executable)
        XCTAssertTrue(ambiguousSuggestion.reason.contains("得分相同"))
        let insufficientSuggestion = try XCTUnwrap(state.suggestions.first { $0.source == insufficient })
        XCTAssertEqual(insufficientSuggestion.directory, sparse)
        XCTAssertFalse(insufficientSuggestion.executable)
        XCTAssertTrue(insufficientSuggestion.reason.contains("不足两个"))
        let unmatchedSuggestion = try XCTUnwrap(state.suggestions.first { $0.source == unmatched })
        XCTAssertNil(unmatchedSuggestion.directory)
        XCTAssertFalse(unmatchedSuggestion.executable)
        XCTAssertTrue(unmatchedSuggestion.reason.contains("未找到匹配"))
        let before = try fixture.fileContents()
        for suggestion in state.suggestions {
            await assertRejected(containing: "分类不明确") {
                _ = try await service.apply([suggestion.id], mode: .both)
            }
        }
        XCTAssertEqual(try fixture.fileContents(), before)
    }

    func testSavedInterruptedPlanRecoversAfterFinalMoveAndCanBeUndone() async throws {
        let fixture = try Fixture(training: false)
        defer { fixture.remove() }
        let source = try fixture.write("invoice.txt", in: fixture.inbox, text: "invoice final move sentinel")
        let state = try interruptedState(fixture: fixture, source: source)
        let operation = try XCTUnwrap(state.operations.first)
        let original = try Data(contentsOf: source)
        try ArchiveFileSystem.move(source: source, target: operation.destination, staging: operation.staging,
                                   expected: operation.fingerprint, maxBytes: fixture.configuration.maxFileBytes)
        // Persist a planned journal as if the process stopped after rename but before committing completion.
        try save(state, directory: fixture.stateDirectory)
        let service = try ArchiveService(directory: fixture.stateDirectory)
        try await service.recover()
        let recovered = await service.snapshot()
        XCTAssertEqual(recovered.operations.first?.status, .complete)
        XCTAssertNil(recovered.operations.first?.error)
        XCTAssertEqual(recovered.suggestions.first?.status, .applied)
        XCTAssertFalse(ArchiveFileSystem.exists(source))
        XCTAssertEqual(try Data(contentsOf: operation.destination), original)
        let beforeSecondRecovery = try fixture.fileContents()
        try await service.recover()
        XCTAssertEqual(try fixture.fileContents(), beforeSecondRecovery)

        try await service.undo(operation.id)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(ArchiveFileSystem.exists(operation.destination))
        let undone = await service.snapshot()
        XCTAssertEqual(undone.operations.first?.status, .undone)
    }

    func testSavedInterruptedPlansPreserveForwardAndUndoStagingDataForReview() async throws {
        for status in [ArchiveOperationStatus.planned, .undoPlanned] {
            let fixture = try Fixture(training: false)
            defer { fixture.remove() }
            let source = try fixture.write("invoice.txt", in: fixture.inbox, text: "staged original sentinel")
            var state = try interruptedState(fixture: fixture, source: source)
            state.operations[0].status = status
            let operation = state.operations[0]
            let staged = status == .planned ? operation.staging : operation.undoStaging
            try FileManager.default.moveItem(at: source, to: staged)
            _ = try fixture.write(source.lastPathComponent, in: fixture.inbox, text: "replacement source sentinel")
            _ = try fixture.write(operation.destination.lastPathComponent, in: fixture.invoices, text: "occupied target sentinel")
            try save(state, directory: fixture.stateDirectory)
            let service = try ArchiveService(directory: fixture.stateDirectory)

            for _ in 0..<2 {
                try await service.recover()
                let recovered = await service.snapshot()
                XCTAssertEqual(recovered.operations.count, 1)
                XCTAssertEqual(recovered.operations.first?.status, .needsReview)
                XCTAssertTrue(recovered.operations.first?.error?.contains(staged.path) == true)
                XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "staged original sentinel")
                XCTAssertEqual(try ArchiveFileSystem.fingerprint(staged, maxBytes: fixture.configuration.maxFileBytes), operation.fingerprint)
                XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "replacement source sentinel")
                XCTAssertEqual(try String(contentsOf: operation.destination, encoding: .utf8), "occupied target sentinel")
            }
        }
    }

    func testSavedUnexecutedAndFinishedUndoPlansAreReconciledWithoutMovingFiles() async throws {
        for status in [ArchiveOperationStatus.planned, .undoPlanned] {
            let fixture = try Fixture(training: false)
            defer { fixture.remove() }
            let source = try fixture.write("invoice.txt", in: fixture.inbox, text: "original source sentinel")
            var state = try interruptedState(fixture: fixture, source: source)
            state.operations[0].status = status
            let operation = state.operations[0]
            try save(state, directory: fixture.stateDirectory)
            let service = try ArchiveService(directory: fixture.stateDirectory)
            try await service.recover()
            let recovered = await service.snapshot()
            XCTAssertEqual(recovered.operations.first?.status, status == .planned ? .notExecuted : .undone)
            XCTAssertEqual(recovered.suggestions.first?.status, status == .planned ? .pending : .skipped)
            XCTAssertNil(recovered.operations.first?.error)
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original source sentinel")
            XCTAssertFalse(ArchiveFileSystem.exists(operation.destination))
            XCTAssertFalse(ArchiveFileSystem.exists(operation.staging))
            XCTAssertFalse(ArchiveFileSystem.exists(operation.undoStaging))
        }
    }

    func testUTF8TextExtractionUsesContentsAndCapsTheTextPrefix() async throws {
        let fixture = try Fixture(training: false)
        defer { fixture.remove() }
        let source = try fixture.write("neutral-record.txt", in: fixture.inbox,
                                       text: "invoice accounting payable 合同资料 " + String(repeating: " ", count: 12_000) + "beyondprefixmarker")
        let before = try Data(contentsOf: source)
        let evidence = try extract(source, fixture: fixture)
        XCTAssertNil(evidence.extractionNote)
        XCTAssertTrue(Set(evidence.words).isSuperset(of: ["neutral", "record", "invoice", "accounting", "payable"]))
        XCTAssertFalse(evidence.words.contains("beyondprefixmarker"))
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(evidence.fingerprint, try ArchiveFileSystem.fingerprint(source, maxBytes: fixture.configuration.maxFileBytes))
    }

    func testInvalidUTF8TextFallsBackToFilenameWithoutLosingTheFile() async throws {
        let fixture = try Fixture(training: false)
        defer { fixture.remove() }
        let source = fixture.inbox.appendingPathComponent("invoice-fallback.txt")
        let invalid = Data([0xFF, 0xFE, 0x80, 0x81])
        try invalid.write(to: source)
        let evidence = try extract(source, fixture: fixture)
        XCTAssertTrue(evidence.extractionNote?.contains("非 UTF-8") == true)
        XCTAssertEqual(Set(evidence.words), ArchiveLearning.tokens("invoice-fallback"))
        XCTAssertEqual(try Data(contentsOf: source), invalid)
    }

    func testSyntheticPDFExtractsPageTextRatherThanOnlyTheFilename() async throws {
        let fixture = try Fixture(training: false)
        defer { fixture.remove() }
        let source = fixture.inbox.appendingPathComponent("neutral-document.pdf")
        let pdf = pdfDocument(text: "invoice accounting payable")
        try pdf.write(to: source)
        let evidence = try extract(source, fixture: fixture)
        XCTAssertNil(evidence.extractionNote)
        XCTAssertTrue(Set(evidence.words).isSuperset(of: ["invoice", "accounting", "payable", "neutral", "document"]))
        XCTAssertEqual(try Data(contentsOf: source), pdf)
    }

    func testStoredAndDeflatedDOCXExtractOnlyDocumentTextAndDecodeEntities() async throws {
        let fixture = try Fixture(training: false)
        defer { fixture.remove() }
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        <w:p><w:r><w:t>invoice accounting &amp; payable</w:t></w:r></w:p>
        <w:p><w:r><w:t>合同资料</w:t></w:r></w:p>
        <w:p><w:r><w:t><![CDATA[cdataword & notes]]></w:t></w:r></w:p>
        </w:body></w:document>
        """.utf8)
        for method: UInt16 in [0, 8] {
            let document = try wordDocument(xml: xml, method: method)
            let text = try ArchiveWordExtractor.text(from: document)
            XCTAssertTrue(text.contains("invoice accounting & payable"))
            XCTAssertTrue(text.contains("合同资料"))
            XCTAssertTrue(text.contains("cdataword & notes"))
            XCTAssertFalse(text.contains("schemas.openxmlformats.org"))
            XCTAssertFalse(text.contains("w:document"))
            let source = fixture.inbox.appendingPathComponent("neutral-document-\(method).docx")
            try document.write(to: source)
            let evidence = try extract(source, fixture: fixture)
            XCTAssertNil(evidence.extractionNote)
            XCTAssertTrue(Set(evidence.words).isSuperset(of: ["invoice", "accounting", "payable"]))
            XCTAssertFalse(evidence.words.contains("openxmlformats"))
            XCTAssertEqual(try Data(contentsOf: source), document)
        }
    }

    func testDOCXFormattingRunsKeepWordsIntactAndSeparateParagraphs() async throws {
        let xml = Data("""
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        <w:p><w:r><w:t>in</w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>voice</w:t></w:r></w:p>
        <w:p><w:r><w:t>accounting</w:t></w:r><w:r><w:tab/><w:t>payable</w:t></w:r></w:p>
        </w:body></w:document>
        """.utf8)
        let text = try ArchiveWordExtractor.text(from: wordDocument(xml: xml, method: 8))
        XCTAssertTrue(text.contains("invoice\naccounting payable"))
        XCTAssertTrue(ArchiveLearning.tokens(text).isSuperset(of: ["invoice", "accounting", "payable"]))
    }

    func testDOCXTextExtractionAcceptsAlternateNamespacePrefixes() async throws {
        let xml = Data("""
        <word:document xmlns:word="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <word:body><word:p><word:r><word:t>invoice namespaceprefix</word:t></word:r></word:p></word:body>
        </word:document>
        """.utf8)
        let document = try wordDocument(xml: xml, method: 8)
        let text = try ArchiveWordExtractor.text(from: document)
        XCTAssertTrue(text.contains("invoice namespaceprefix"))
    }

    func testDOCXDeclaredXMLOverFiveMBIsRejectedBeforeExpansionAndFallsBackToFilename() async throws {
        let fixture = try Fixture(training: false)
        defer { fixture.remove() }
        let xml = Data("<w:document xmlns:w=\"urn:test\"><w:t>hiddenbodymarker</w:t></w:document>".utf8)
        for method: UInt16 in [0, 8] {
            let document = try wordDocument(xml: xml, method: method, declaredXMLBytes: 5_000_001)
            XCTAssertLessThan(document.count, 1_000, "The fixture declares oversized XML without allocating it.")
            XCTAssertThrowsError(try ArchiveWordExtractor.text(from: document)) { error in
                XCTAssertTrue(error is ArchiveError)
                XCTAssertTrue(error.localizedDescription.contains("5 MB"))
            }
            let source = fixture.inbox.appendingPathComponent("invoice-oversized-\(method).docx")
            try document.write(to: source)
            let evidence = try extract(source, fixture: fixture)
            XCTAssertTrue(evidence.extractionNote?.contains("5 MB") == true)
            XCTAssertTrue(evidence.extractionNote?.contains("仅使用文件名") == true)
            XCTAssertFalse(evidence.words.contains("hiddenbodymarker"))
            XCTAssertEqual(Set(evidence.words), ArchiveLearning.tokens(source.deletingPathExtension().lastPathComponent))
            XCTAssertEqual(try Data(contentsOf: source), document)
        }
    }

    func testCorruptDOCXZIPsAndMalformedXMLAreRejectedAndPreserved() async throws {
        let fixture = try Fixture(training: false)
        defer { fixture.remove() }
        let xml = Data("<w:document xmlns:w=\"urn:test\"><w:t>invoice</w:t></w:document>".utf8)
        let valid = try wordDocument(xml: xml, method: 0)
        var invalidDirectory = valid
        let directoryOffset = 30 + Data("word/document.xml".utf8).count + xml.count
        invalidDirectory[directoryOffset] = 0
        var invalidLocalHeader = valid
        invalidLocalHeader[0] = 0
        let malformedXML = try wordDocument(xml: Data("<document><t>unclosed".utf8), method: 0)
        let corruptDocuments = [
            Data("not a zip".utf8),
            Data(valid.dropLast()),
            invalidDirectory,
            invalidLocalHeader,
            malformedXML,
            try wordDocument(xml: xml, method: 8, payload: Data([0xFF, 0xFF, 0xFF])),
        ]
        for (index, document) in corruptDocuments.enumerated() {
            XCTAssertThrowsError(try ArchiveWordExtractor.text(from: document)) { error in
                XCTAssertTrue(error is ArchiveError, "Unexpected error for corrupt fixture \(index): \(error)")
            }
            let source = fixture.inbox.appendingPathComponent("invoice-corrupt-\(index).docx")
            try document.write(to: source)
            let evidence = try extract(source, fixture: fixture)
            XCTAssertNotNil(evidence.extractionNote)
            XCTAssertTrue(evidence.extractionNote?.contains("仅使用文件名") == true)
            XCTAssertEqual(Set(evidence.words), ArchiveLearning.tokens(source.deletingPathExtension().lastPathComponent))
            XCTAssertEqual(try Data(contentsOf: source), document)
        }
    }

    private func assertModeRoundTrip(_ mode: ArchiveApplyMode) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try ArchiveService(directory: fixture.stateDirectory)
        try await prepare(service, fixture: fixture)
        let source = try fixture.write("invoice  report.txt.txt", in: fixture.inbox, text: "invoice accounting payable")
        let original = try Data(contentsOf: source)
        let suggestion = try await stableSuggestion(service, source: source)
        XCTAssertNotEqual(suggestion.proposedName, source.lastPathComponent)
        let applied = try await service.apply([suggestion.id], mode: mode)
        let operation = try XCTUnwrap(applied.first)
        let expected = mode == .move
            ? fixture.invoices.appendingPathComponent(source.lastPathComponent)
            : fixture.inbox.appendingPathComponent(suggestion.proposedName)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(operation.status, .complete)
        XCTAssertEqual(operation.destination, expected)
        XCTAssertEqual(try Data(contentsOf: expected), original)
        XCTAssertFalse(ArchiveFileSystem.exists(source))
        XCTAssertFalse(ArchiveFileSystem.exists(fixture.invoices.appendingPathComponent(suggestion.proposedName)))
        if mode == .rename {
            XCTAssertFalse(ArchiveFileSystem.exists(fixture.invoices.appendingPathComponent(source.lastPathComponent)))
        }
        try await service.undo(operation.id)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(ArchiveFileSystem.exists(expected))
        XCTAssertFalse(ArchiveFileSystem.exists(operation.staging))
        XCTAssertFalse(ArchiveFileSystem.exists(operation.undoStaging))
        let state = await service.snapshot()
        XCTAssertEqual(state.operations.first?.status, .undone)
        XCTAssertEqual(state.suggestions.first?.status, .skipped)
    }

    private func extract(_ source: URL, fixture: Fixture) throws -> ArchiveEvidence {
        let evidence = ArchiveEvidence(url: source,
            fingerprint: try ArchiveFileSystem.fingerprint(source, maxBytes: fixture.configuration.maxFileBytes),
            words: [], extractionNote: nil)
        return try ArchiveLearning.extract(evidence, maxBytes: fixture.configuration.maxFileBytes)
    }

    private func pdfDocument(text: String) -> Data {
        // A complete one-page PDF with a built-in font and a byte-accurate cross-reference table.
        // The caller supplies synthetic ASCII text without PDF string delimiters.
        let stream = "BT /F1 12 Tf 40 100 Td (\(text)) Tj ET\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream",
        ]
        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let crossReference = pdf.count
        pdf.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        pdf.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(crossReference)\n%%EOF\n".utf8))
        return pdf
    }

    private func wordDocument(xml: Data, method: UInt16, declaredXMLBytes: UInt32? = nil,
                              payload: Data? = nil) throws -> Data {
        let name = Data("word/document.xml".utf8)
        let compressed: Data
        if let payload { compressed = payload }
        else if method == 8 {
            var buffer = [UInt8](repeating: 0, count: xml.count * 2 + 256)
            let count = buffer.withUnsafeMutableBufferPointer { destination in
                xml.withUnsafeBytes { source in
                    compression_encode_buffer(destination.baseAddress!, destination.count,
                        source.bindMemory(to: UInt8.self).baseAddress!, xml.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard count > 0 else { throw ArchiveError("无法生成测试 DEFLATE 数据。") }
            compressed = Data(buffer.prefix(count))
        } else { compressed = xml }
        let expanded = declaredXMLBytes ?? UInt32(xml.count)
        let crc = crc32(xml)
        var zip = Data()
        func append(_ value: UInt64, bytes: Int) {
            for index in 0..<bytes { zip.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        // Local file header, followed by the only ZIP member's data.
        append(0x04034B50, bytes: 4)
        append(20, bytes: 2)
        append(0, bytes: 2)
        append(UInt64(method), bytes: 2)
        append(0, bytes: 2)
        append(0x0021, bytes: 2)
        append(UInt64(crc), bytes: 4)
        append(UInt64(compressed.count), bytes: 4)
        append(UInt64(expanded), bytes: 4)
        append(UInt64(name.count), bytes: 2)
        append(0, bytes: 2)
        zip.append(name)
        zip.append(compressed)
        let directoryStart = zip.count
        // Central directory, matching the local member and its CRC/size declarations.
        append(0x02014B50, bytes: 4)
        append(20, bytes: 2)
        append(20, bytes: 2)
        append(0, bytes: 2)
        append(UInt64(method), bytes: 2)
        append(0, bytes: 2)
        append(0x0021, bytes: 2)
        append(UInt64(crc), bytes: 4)
        append(UInt64(compressed.count), bytes: 4)
        append(UInt64(expanded), bytes: 4)
        append(UInt64(name.count), bytes: 2)
        append(0, bytes: 2)
        append(0, bytes: 2)
        append(0, bytes: 2)
        append(0, bytes: 2)
        append(0, bytes: 4)
        append(0, bytes: 4)
        zip.append(name)
        let directorySize = zip.count - directoryStart
        append(0x06054B50, bytes: 4)
        append(0, bytes: 2)
        append(0, bytes: 2)
        append(1, bytes: 2)
        append(1, bytes: 2)
        append(UInt64(directorySize), bytes: 4)
        append(UInt64(directoryStart), bytes: 4)
        append(0, bytes: 2)
        return zip
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB88320)
            }
        }
        return ~crc
    }

    private func prepare(_ service: ArchiveService, fixture: Fixture) async throws {
        try await service.configure(fixture.configuration)
        let warnings = try await service.learn()
        XCTAssertTrue(warnings.isEmpty, warnings.joined(separator: "\n"))
    }

    private func stableSuggestion(_ service: ArchiveService, source: URL,
                                  firstSeen: Date = Date().addingTimeInterval(-3)) async throws -> ArchiveSuggestion {
        _ = try await service.suggest(now: firstSeen)
        _ = try await service.suggest(now: firstSeen.addingTimeInterval(2))
        let state = await service.snapshot()
        let suggestion = try XCTUnwrap(state.suggestions.first { $0.source == source && $0.status == .pending })
        XCTAssertTrue(suggestion.executable)
        return suggestion
    }

    private func assertRejected(containing message: String, file: StaticString = #filePath, line: UInt = #line,
                                operation: @MainActor () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected rejection containing: \(message)", file: file, line: line)
        } catch {
            XCTAssertTrue(error is ArchiveError, "Unexpected error: \(error)", file: file, line: line)
            XCTAssertTrue(error.localizedDescription.contains(message), error.localizedDescription, file: file, line: line)
        }
    }

    private func encoded(_ state: ArchiveState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    private func interruptedState(fixture: Fixture, source: URL) throws -> ArchiveState {
        let fingerprint = try ArchiveFileSystem.fingerprint(source, maxBytes: fixture.configuration.maxFileBytes)
        let suggestion = ArchiveSuggestion(source: source, fingerprint: fingerprint, directory: fixture.invoices,
                                           proposedName: source.lastPathComponent, reason: "Synthetic recovery fixture",
                                           executable: true, extractionNote: nil, version: 1)
        let operation = ArchiveOperation(suggestionID: suggestion.id, source: source,
                                         destination: fixture.invoices.appendingPathComponent(source.lastPathComponent),
                                         fingerprint: fingerprint,
                                         staging: fixture.inbox.appendingPathComponent(".inchspace-archive-forward"),
                                         undoStaging: fixture.invoices.appendingPathComponent(".inchspace-archive-undo"))
        var state = ArchiveState()
        state.configuration = fixture.configuration
        state.version = 1
        state.suggestions = [suggestion]
        state.operations = [operation]
        return state
    }

    private func save(_ state: ArchiveState, directory: URL) throws {
        // Keep the persistence writer in this synchronous scope; it releases flock before a service opens it.
        let persistence = try ArchivePersistence(directory: directory)
        try persistence.save(state)
    }

    private struct Fixture {
        let root: URL
        let inbox: URL
        let library: URL
        let invoices: URL
        let stateDirectory: URL

        var configuration: ArchiveConfiguration {
            ArchiveConfiguration(folders: [
                ArchiveFolder(role: .inbox, url: inbox, bookmark: nil),
                ArchiveFolder(role: .library, url: library, bookmark: nil),
            ])
        }

        init(training: Bool = true) throws {
            let temporaryDirectory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory
            guard let resolved = realpath(temporaryDirectory.path, nil) else { throw ArchiveError("无法解析测试临时目录。") }
            let canonicalTemporaryDirectory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
            root = canonicalTemporaryDirectory
                .appendingPathComponent("inchspace-archive-tests-\(UUID().uuidString)", isDirectory: true)
            inbox = root.appendingPathComponent("Inbox", isDirectory: true)
            library = root.appendingPathComponent("Library", isDirectory: true)
            invoices = library.appendingPathComponent("Invoices", isDirectory: true)
            stateDirectory = root.appendingPathComponent("State", isDirectory: true)
            do {
                for directory in [inbox, invoices, stateDirectory] {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                if training {
                    let research = try directory("Research", in: library)
                    // Five samples per class leave more than two training examples after holdout.
                    for index in 1...5 {
                        _ = try write("invoice-history-\(index).txt", in: invoices, text: "invoice accounting payable")
                        _ = try write("quantum-history-\(index).txt", in: research, text: "quantum experiment physics")
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        func directory(_ name: String, in parent: URL? = nil) throws -> URL {
            let url = (parent ?? root).appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func write(_ name: String, in parent: URL, text: String) throws -> URL {
            let url = parent.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return url
        }

        func fileContents() throws -> [String: Data] {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey], options: []))
            var contents: [String: Data] = [:]
            for case let url as URL in enumerator {
                // SQLite's shared-memory index is rebuilt by any transaction, even one that writes nothing; it
                // holds no data. The database and its write-ahead log are still compared.
                guard !url.lastPathComponent.hasSuffix("-shm") else { continue }
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    contents[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
                }
            }
            return contents
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
