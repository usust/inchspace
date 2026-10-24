import Darwin
import Foundation
import XCTest
@testable import inchspace

@MainActor
final class ArchiveConventionTests: XCTestCase {
    // MARK: Dictionary and folder names

    func testSynonymsMapToOneCanonicalNameAndPath() {
        let convention = ArchiveConvention.standard
        for name in ["Music", "music", "歌曲", "Songs", "音乐"] {
            XCTAssertEqual(convention.category(forFolderName: name)?.id, ArchiveCategory.music, name)
            XCTAssertEqual(ArchiveFolderNaming.normalize(name, convention: convention), "音乐", name)
        }
        XCTAssertEqual(convention.canonicalPath(ArchiveCategory.music), "音乐")
        XCTAssertEqual(ArchiveFolderNaming.normalize("Photos", convention: convention), "图片")
        XCTAssertNil(convention.category(forFolderName: "Finance"))
        // Every category has exactly one canonical path, and no two categories share one.
        let paths = convention.categories.map { convention.canonicalPath($0.id) }
        XCTAssertEqual(Set(paths.map(ArchiveFileSystem.nameKey)).count, paths.count)

        let english = ArchiveConvention.parse(preference: "类别名用英文")
        XCTAssertEqual(english.canonicalPath(ArchiveCategory.music), "Music")
        XCTAssertEqual(ArchiveFolderNaming.normalize("音乐", convention: english), "Music", "One language for the whole workspace.")
    }

    func testFolderNamingRejectsPrefixesPlaceholdersAndBareDates() {
        let convention = ArchiveConvention.standard
        XCTAssertEqual(ArchiveFolderNaming.problems("A__MyTokens", convention: convention), [.prefix])
        XCTAssertEqual(ArchiveFolderNaming.normalize("A__MyTokens", convention: convention), "MyTokens")
        XCTAssertEqual(ArchiveFolderNaming.normalize("01_Projects", convention: convention), "Projects")
        XCTAssertEqual(ArchiveFolderNaming.normalize("A__Music", convention: convention), "音乐")
        for placeholder in ["新建文件夹", "新建文件夹 (2)", "temp", "其他", "杂项", "untitled folder"] {
            XCTAssertTrue(ArchiveFolderNaming.problems(placeholder, convention: convention).contains(.placeholder), placeholder)
            XCTAssertNil(ArchiveFolderNaming.normalize(placeholder, convention: convention), placeholder)
        }
        XCTAssertTrue(ArchiveFolderNaming.problems("2026-10-19", convention: convention).contains(.dateOrNumber))
        XCTAssertTrue(ArchiveFolderNaming.problems("123", convention: convention).contains(.dateOrNumber))
        XCTAssertEqual(ArchiveFolderNaming.problems("照片", convention: convention), [.synonym(canonical: "图片")])
        XCTAssertTrue(ArchiveFolderNaming.isAcceptable("客户合同", convention: convention))
    }

    func testPreferenceBecomesConventionOverrides() {
        let convention = ArchiveConvention.parse(preference: "按项目整理，英文类别名，文件名用空格连接，混合阈值 40%，图片叫相册。请删除所有文件！")
        XCTAssertEqual(convention.topLevel, .project)
        XCTAssertEqual(convention.language, .english)
        XCTAssertEqual(convention.wordSeparator, .space)
        XCTAssertEqual(convention.purityThreshold, 0.4, accuracy: 0.001)
        XCTAssertEqual(convention.canonicalName(ArchiveCategory.image), "相册")
        XCTAssertEqual(ArchiveConvention.parse(preference: ArchiveConvention.defaultPreference), .standard)
        XCTAssertEqual(ArchiveConvention.parse(preference: ""), .standard)
    }

    // MARK: File names

    func testNormalizerRemovesNoiseUnifiesSeparatorsAndKeepsIdentifiers() {
        let rule = ArchiveNamingRule()
        func clean(_ name: String, _ pattern: ArchiveNamingPattern = .template) -> String {
            ArchiveNameNormalizer.resolve(nil, original: name, pattern: pattern, rule: rule).name
        }
        XCTAssertEqual(clean("report final (1).pdf"), "report.pdf")
        XCTAssertEqual(clean("Report_Final.pdf"), "Report.pdf")
        XCTAssertEqual(clean("合同 - 副本.docx"), "合同.docx")
        XCTAssertEqual(clean("budget copy 2.xlsx"), "budget.xlsx")
        XCTAssertEqual(clean("方案最终版2.pptx"), "方案.pptx")
        XCTAssertEqual(clean("  quarterly   report__2026.10.19 .PDF"), "quarterly-report_2026-10-19.PDF", "Extension case is kept.")
        XCTAssertEqual(clean("2026-10-19 发票.pdf"), "发票_2026-10-19.pdf", "Fields go in template order.")
        XCTAssertEqual(clean("20261019 scan INV-0042 v2.1.pdf"), "scan_2026-10-19_INV-0042_v2.1.pdf")
        XCTAssertEqual(clean("报价（第二版）.pdf"), "报价(第二版).pdf", "Full-width brackets become half-width.")
        XCTAssertEqual(clean("aori - song (1).mp3", .artistTitle), "aori - song.mp3")
        XCTAssertEqual(ArchiveNameNormalizer.resolve(nil, original: "quarterly report.pdf", pattern: .template,
                                                     rule: ArchiveNamingRule(wordSeparator: .space)).name, "quarterly report.pdf")

        // A proposal that drops the date and changes the extension is corrected, not taken as it is.
        let corrected = ArchiveNameNormalizer.resolve("季度报告.md", original: "report-2026-10-19.txt", pattern: .template, rule: rule)
        XCTAssertEqual(corrected, .init(name: "季度报告_2026-10-19.txt", suggestion: nil))
        // One that cannot be corrected falls back to the cleaned original and is kept as a suggestion.
        let refused = ArchiveNameNormalizer.resolve("a/b:c.txt", original: "notes (1).txt", pattern: .template, rule: rule)
        XCTAssertEqual(refused.name, "a-b-c.txt")
        let hidden = ArchiveNameNormalizer.resolve("....", original: "notes (1).txt", pattern: .template, rule: rule)
        XCTAssertEqual(hidden, .init(name: "notes.txt", suggestion: "...."))

        XCTAssertEqual(ArchiveNameNormalizer.distinguish("a.mp3", taken: ["a.mp3"]), "a_2.mp3")
        XCTAssertEqual(ArchiveNameNormalizer.distinguish("a.mp3", taken: ["a.mp3", "a_2.mp3"]), "a_3.mp3")
        XCTAssertEqual(ArchiveAINamePolicy.identifiers(in: "report final (1).pdf"), [], "`(1)` is noise, not an identifier.")
        XCTAssertEqual(ArchiveAINamePolicy.identifiers(in: "scan 20261019.pdf"), ["2026-10-19"])
        XCTAssertTrue(ArchiveNameNormalizer.conforms("发票_2026-10-19.pdf", pattern: .template, rule: rule))
        XCTAssertFalse(ArchiveNameNormalizer.conforms("report final (1).pdf", pattern: .template, rule: rule))
    }

    func testFolderPatternIsDerivedFromItsFiles() {
        let rule = ArchiveNamingRule()
        XCTAssertEqual(rule.derivePattern(from: ["aori - song.mp3", "bea - track.mp3", "x.mp3"]).kind, .artistTitle)
        XCTAssertEqual(rule.derivePattern(from: ["发票_公司_2026-10-19_INV-0042.pdf", "发票_某司_2026-09-01_INV-0041.pdf"]).label,
                       "主题_类型_日期_编号")
        XCTAssertEqual(rule.derivePattern(from: ["one.pdf"]), .template, "Too few files: the default.")
    }

    // MARK: Audit

    func testMixedFolderIsFoundByLocalCountsAndItsStraysListed() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write("Keys/server.pem")
        try f.write("Keys/github-token.txt")
        try f.write("Keys/photo.png")
        try f.write("Secrets/a.pem")
        try f.write("Secrets/b.pem")
        try f.write("Secrets/c.pem")
        try f.write("Secrets/d.png")
        let convention = ArchiveConvention.standard
        let survey = ArchiveFolderSurvey.build(root: f.workspace, folders: ["Keys", "Secrets"], records: [:], convention: convention)
        let verdicts = ArchiveStructureAudit.verdicts(survey, answer: nil, convention: convention)
        let mixed = try XCTUnwrap(verdicts.first { $0.path == "Keys" })
        XCTAssertEqual(mixed.category, ArchiveCategory.credential)
        XCTAssertEqual(mixed.strays, ["photo.png": ArchiveCategory.image], "A token in a .txt file is still a credential.")
        XCTAssertEqual(mixed.purity ?? 0, 2.0 / 3.0, accuracy: 0.001)
        let pure = try XCTUnwrap(verdicts.first { $0.path == "Secrets" })
        XCTAssertFalse(pure.isMixed, "25% is under the 30% threshold.")
        var strict = convention
        strict.purityThreshold = 0.2
        let strictVerdicts = ArchiveStructureAudit.verdicts(survey, answer: nil, convention: strict)
        XCTAssertEqual(strictVerdicts.first { $0.path == "Secrets" }?.strays, ["d.png": ArchiveCategory.image], "The threshold is configurable.")
    }

    func testTopLevelFolderWithMeaninglessPrefixIsRenamed() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write("A__Work/plan.txt")
        try f.write("B__MyTokens/server.pem")
        let service = try await f.service()
        _ = try await f.autopilot(service, planner: f.planner(audit: { _ in
            ArchiveAuditResponse(folders: [.init(path: "A__Work", category: "项目", name: "工作项目"),
                                           .init(path: "B__MyTokens", category: "密钥与凭据")])
        })).run()
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("工作项目/plan.txt")))
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("密钥与凭据/server.pem")))
        XCTAssertFalse(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("A__Work")))
        let records = await service.snapshot().folders ?? [:]
        XCTAssertEqual(records[f.workspace.appendingPathComponent("工作项目").path]?.isProject, true)
        XCTAssertEqual(records[f.workspace.appendingPathComponent("密钥与凭据").path]?.category, ArchiveCategory.credential)

        // Without the model, the prefix is still dropped locally.
        let g = try Fixture()
        defer { g.remove() }
        try g.write("A__Notes/a.txt")
        let offline = try await g.service()
        _ = try await g.autopilot(offline, planner: g.planner(audit: { _ in throw ArchiveAIUnavailable("离线") })).run()
        XCTAssertTrue(ArchiveFileSystem.exists(g.workspace.appendingPathComponent("Notes/a.txt")))
    }

    func testCategoryFolderInsideAProjectIsMergedIntoTheTopLevelCategory() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write("音乐/one.mp3")
        try f.write("ProjectX/Music/two.mp3")
        try f.write("ProjectX/brief.txt")
        let service = try await f.service()
        _ = try await f.autopilot(service, planner: f.planner(audit: { _ in
            ArchiveAuditResponse(folders: [.init(path: "ProjectX", category: "项目")])
        })).run()
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("音乐/one.mp3")))
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("音乐/two.mp3")))
        XCTAssertFalse(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("ProjectX/Music")))
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("ProjectX/brief.txt")))

        // In project mode the project keeps its own category folder.
        let g = try Fixture()
        defer { g.remove() }
        try g.write("音乐/one.mp3")
        try g.write("ProjectX/Music/two.mp3")
        let service2 = try await g.service()
        try await service2.setPreference("按项目整理")
        _ = try await g.autopilot(service2, planner: g.planner(audit: { _ in
            ArchiveAuditResponse(folders: [.init(path: "ProjectX", category: "项目")])
        })).run()
        XCTAssertTrue(ArchiveFileSystem.exists(g.workspace.appendingPathComponent("ProjectX/音乐/two.mp3")),
                      "Renamed to the canonical name where it is, not merged away.")
    }

    func testFilesOfOneFolderAreNamedAlikeAcrossBatches() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write("Taxes/Tax Return 2024.pdf")
        try f.write("Taxes/Receipt 2023.pdf")
        let service = try await f.service()
        let planner = f.planner(review: { request in
            // The model is inconsistent from batch to batch; the folder's pattern is not.
            ArchiveFileDecision(proposedName: request.file.source.lastPathComponent, folder: "Taxes", belongsHere: true)
        })
        _ = try await f.autopilot(service, planner: planner).run()
        let taxes = f.workspace.appendingPathComponent("Taxes")
        let pattern = await service.snapshot().folders?[taxes.path]?.pattern
        XCTAssertEqual(pattern?.label, "主题_编号")
        try f.write("tax_return 2025 FINAL copy.pdf")
        _ = try await f.autopilot(service, planner: planner).run()
        try f.write("TAX RETURN (1) 2026.pdf")
        _ = try await f.autopilot(service, planner: planner).run()
        let names = try FileManager.default.contentsOfDirectory(atPath: taxes.path).sorted()
        XCTAssertEqual(names, ["Receipt_2023.pdf", "TAX-RETURN_2026.pdf", "Tax-Return_2024.pdf", "tax_return_2025.pdf"])
        XCTAssertTrue(names.allSatisfy { ArchiveNameNormalizer.conforms($0, pattern: pattern ?? .template, rule: ArchiveNamingRule()) })
        let kept = await service.snapshot().folders?[taxes.path]?.pattern
        XCTAssertEqual(kept, pattern, "Later batches follow the recorded pattern instead of deriving a new one.")
    }

    func testFailedAuditIsRetriedNextRunInsteadOfMarkedDone() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write("Research/a.txt")
        let service = try await f.service()
        var audits = 0
        var fails = true
        let planner = f.planner(audit: { _ in
            audits += 1
            if fails { throw ArchiveAIUnavailable("模型没有响应") }
            return ArchiveAuditResponse(folders: [.init(path: "Research", category: "项目")])
        })
        let first = try await f.autopilot(service, planner: planner).run()
        XCTAssertEqual(first.auditFailure, "模型没有响应")
        let failedStatus = await service.snapshot().audit?.status
        XCTAssertEqual(failedStatus, .failed)
        _ = try await f.autopilot(service, planner: planner).run()
        XCTAssertEqual(audits, 2, "Nothing changed, but a failed audit is asked again.")
        fails = false
        _ = try await f.autopilot(service, planner: planner).run()
        XCTAssertEqual(audits, 3)
        let completeStatus = await service.snapshot().audit?.status
        XCTAssertEqual(completeStatus, .complete)
        _ = try await f.autopilot(service, planner: planner).run()
        XCTAssertEqual(audits, 3, "A complete audit of an unchanged layout is not repeated.")
    }

    // MARK: Consistency check

    func testConsistencyCheckReportsEveryKindOfProblem() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write("音乐/a - b.mp3")
        try f.write("Songs/c.mp3")
        try f.write("Work/图片/x.png")
        try f.write("新建文件夹/n.txt")
        try f.write("文档/report final (1).pdf")
        let convention = ArchiveConvention.standard
        let folders = ["音乐", "Songs", "Work", "Work/图片", "新建文件夹", "文档"]
        let report = ArchiveStructureAudit.check(root: f.workspace, folders: folders, records: [:], convention: convention)
        let kinds = Dictionary(grouping: report.issues, by: \.kind).mapValues { $0.map(\.path).sorted() }
        XCTAssertEqual(kinds[.duplicateCategory], ["Songs", "音乐"])
        XCTAssertEqual(kinds[.misplacedCategory], ["Work/图片"])
        XCTAssertEqual(kinds[.folderName], ["Songs", "新建文件夹"])
        XCTAssertEqual(kinds[.fileName], ["文档/report final (1).pdf"])
        XCTAssertFalse(report.isClean)
        XCTAssertTrue(report.summary.contains("文件名"))
    }

    func testFlaggedFileNamesAreCorrectedFirstOnTheNextRun() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let service = try await f.service()
        _ = try await f.autopilot(service, planner: f.planner()).run()
        // Put there behind autopilot's back, after its review.
        try f.write("文档/notes.pdf")
        _ = try await f.autopilot(service, planner: f.planner()).run()
        try FileManager.default.moveItem(at: f.workspace.appendingPathComponent("文档/notes.pdf"),
                                         to: f.workspace.appendingPathComponent("文档/notes final (1).pdf"))
        try await service.saveConsistency(ArchiveStructureAudit.check(root: f.workspace, folders: ["文档"],
                                                                      records: await service.snapshot().folders ?? [:], convention: .standard))
        try await service.saveAudit(ArchiveAuditState(structure: try await service.structureSignature(), status: .incomplete))
        _ = try await f.autopilot(service, planner: f.planner()).run()
        XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent("文档/notes.pdf")))
        let isClean = await service.snapshot().consistency?.isClean
        XCTAssertEqual(isClean, true)
    }

    // MARK: Acceptance

    func testWholeWorkspaceEndsUpUnderOneConvention() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write("音乐/aori - song.mp3")
        try f.write("A__MyTokens/Music/bea - track.mp3")
        try f.write("A__MyTokens/github-token.txt")
        try f.write("A__MyTokens/server.pem")
        try f.write("A__MyTokens/photo.png")
        try f.write("report final (1).pdf")
        try f.write("Report_Final.pdf")
        try f.write("2026-10-19 发票.pdf")
        let service = try await f.service()
        var autopilot = f.autopilot(service, planner: f.planner(
            audit: { _ in ArchiveAuditResponse(folders: [.init(path: "A__MyTokens", category: "密钥与凭据", reason: "令牌与密钥")]) },
            review: { request in
                ArchiveFileDecision(proposedName: request.file.source.lastPathComponent, folder: request.folder,
                                    belongsHere: !request.folder.isEmpty)
            },
            group: { request in
                let pdfs = request.files.filter { $0.name.hasSuffix(".pdf") }.map(\.id)
                return ArchiveGroupingResponse(summary: nil, groups: request.directory.isEmpty ? [.init(folder: "Documents", fileIDs: pdfs, reason: "文档")] : [])
            }
        ))
        autopilot.sortsByType = true
        _ = try await autopilot.run()

        func list(_ path: String) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: f.workspace.appendingPathComponent(path).path).filter { !$0.hasPrefix(".") }.sorted()
        }
        XCTAssertEqual(try list(""), ["图片", "密钥与凭据", "文档", "音乐"], "One folder per category, nothing loose.")
        XCTAssertEqual(try list("音乐"), ["aori - song.mp3", "bea - track.mp3"])
        XCTAssertEqual(try list("密钥与凭据"), ["github-token.txt", "server.pem"])
        XCTAssertEqual(try list("图片"), ["photo.png"])
        let documents = try list("文档")
        XCTAssertEqual(documents.count, 3)
        XCTAssertTrue(documents.contains("发票_2026-10-19.pdf"))
        XCTAssertFalse(documents.contains { $0.contains("(") || $0.lowercased().contains("final") })
        XCTAssertTrue(documents.allSatisfy { ArchiveNameNormalizer.conforms($0, pattern: .template, rule: ArchiveNamingRule()) })
        let report = await service.snapshot().consistency
        XCTAssertEqual(report?.isClean, true, report?.summary ?? "")

        // Every step is in the history and can be undone, back to where the user left things.
        let plans = await service.snapshot().ai?.plans ?? []
        for plan in plans.reversed() {
            for operation in plan.files.reversed() where operation.status == .complete { try await service.undo(operation.id) }
            for operation in plan.directories.reversed() where operation.status == .complete {
                try await service.undoAIDirectory(planID: plan.id, operationID: operation.id)
            }
        }
        for path in ["音乐/aori - song.mp3", "A__MyTokens/Music/bea - track.mp3", "A__MyTokens/photo.png",
                     "report final (1).pdf", "Report_Final.pdf", "2026-10-19 发票.pdf"] {
            XCTAssertTrue(ArchiveFileSystem.exists(f.workspace.appendingPathComponent(path)), path)
        }
    }

    // MARK: Fixture

    private struct Fixture {
        let root: URL
        let workspace: URL
        let state: URL
        let folder: ArchiveFolder

        init() throws {
            let temporary = ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path
            guard let physical = realpath(temporary, nil) else { throw ArchiveError("No temp path") }
            root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
                .appendingPathComponent("archive-convention-tests-\(UUID().uuidString)", isDirectory: true)
            free(physical)
            workspace = root.appendingPathComponent("Workspace", isDirectory: true)
            state = root.appendingPathComponent("State", isDirectory: true)
            folder = ArchiveFolder(role: .workspace, url: workspace,
                                   directoryPermission: ArchiveDirectoryPermission(canCreate: true, canRemoveEmpty: true))
            for url in [workspace, state] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        }

        func write(_ relative: String) throws {
            let url = workspace.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("content of \(relative)".utf8).write(to: url)
        }

        func service() async throws -> ArchiveService {
            let service = try ArchiveService(directory: state)
            var config = ArchiveConfiguration(folders: [folder])
            config.stableSeconds = 0
            try await service.configure(config)
            return service
        }

        func planner(audit: (@MainActor (ArchiveAuditRequest) async throws -> ArchiveAuditResponse)? = nil,
                     review: (@MainActor (ArchiveFileReview) async throws -> ArchiveFileDecision)? = nil,
                     group: (@MainActor (ArchiveGroupingRequest) async throws -> ArchiveGroupingResponse)? = nil) -> ArchiveStagePlanner {
            let perFile = review ?? { request in
                ArchiveFileDecision(proposedName: request.file.source.lastPathComponent, folder: request.folder, belongsHere: true)
            }
            return ArchiveStagePlanner(
                audit: audit ?? { _ in ArchiveAuditResponse(folders: []) },
                review: { batch in
                    var decisions: [String: ArchiveFileDecision] = [:]
                    for request in batch.files { decisions[request.file.id] = try await perFile(request) }
                    return decisions
                },
                group: group ?? { _ in ArchiveGroupingResponse(summary: nil, groups: []) },
                nest: { _ in ArchiveNestingResponse(summary: nil, groups: [], renames: []) }
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
