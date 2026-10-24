import Darwin
import Foundation
import XCTest
@testable import inchspace

@MainActor
final class ArchiveAIPlanningTests: XCTestCase {
    func testLegacyStateDecodesWithDirectoryPowersDisabled() throws {
        var old = ArchiveState()
        old.configuration.folders = [ArchiveFolder(role: .library, url: URL(fileURLWithPath: "/LibraryExample"))]
        let data = try JSONEncoder().encode(old)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "ai")
        var configuration = try XCTUnwrap(object["configuration"] as? [String: Any])
        var folders = try XCTUnwrap(configuration["folders"] as? [[String: Any]])
        folders[0].removeValue(forKey: "directoryPermission")
        configuration["folders"] = folders
        object["configuration"] = configuration
        let loaded = try JSONDecoder().decode(ArchiveState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(loaded.ai)
        XCTAssertNil(loaded.configuration.folders[0].directoryPermission)
    }

    func testCreateMoveRemoveAndUndoPreserveFileData() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file("invoice-2026.txt")
        let empty = try f.directory("Obsolete", root: f.library)
        let service = try await f.service()
        let context = try await f.context(service)
        let file = try XCTUnwrap(context.files.first)
        let response = f.response(file: file, creates: ["Finance", "Finance/Invoices"], removes: ["Obsolete"])
        let before = try Data(contentsOf: source)
        let preview = try await service.previewAI(response, contextID: context.id)
        XCTAssertFalse(ArchiveFileSystem.exists(f.library.appendingPathComponent("Finance")))
        XCTAssertTrue(ArchiveFileSystem.exists(empty))
        XCTAssertTrue(ArchiveFileSystem.exists(source))
        let untouched = await service.snapshot()
        XCTAssertNil(untouched.ai)
        XCTAssertTrue(untouched.operations.isEmpty)
        let completed = try await service.applyAI(preview.id)
        XCTAssertEqual(completed.status, .complete, completed.error ?? "")
        XCTAssertTrue(completed.directories.allSatisfy { $0.status == .complete })
        XCTAssertFalse(ArchiveFileSystem.exists(source))
        XCTAssertFalse(ArchiveFileSystem.exists(empty))
        let moved = try XCTUnwrap(completed.files.first)
        XCTAssertEqual(try Data(contentsOf: moved.destination), before)
        let saved = await service.snapshot()
        XCTAssertEqual(saved.operations.first?.status, .complete)
        XCTAssertEqual(saved.ai?.plans.first?.status, .complete)
        // Empty-only undo must refuse while the newly created category still holds a file.
        let child = try XCTUnwrap(completed.directories.first { $0.target.lastPathComponent == "Invoices" })
        await rejected { try await service.undoAIDirectory(planID: completed.id, operationID: child.id) }
        XCTAssertEqual(try Data(contentsOf: moved.destination), before)
        try await service.undo(moved.id)
        XCTAssertEqual(try Data(contentsOf: source), before)
        try await service.undoAIDirectory(planID: completed.id, operationID: child.id)
        let parent = try XCTUnwrap(completed.directories.first { $0.target.lastPathComponent == "Finance" })
        try await service.undoAIDirectory(planID: completed.id, operationID: parent.id)
        let deleted = try XCTUnwrap(completed.directories.first { $0.action == .removeEmpty })
        try await service.undoAIDirectory(planID: completed.id, operationID: deleted.id)
        XCTAssertTrue(try ArchiveDirectoryFileSystem.isEmpty(empty))
        let undone = await service.snapshot()
        XCTAssertEqual(undone.operations.first?.status, .undone, "Directory undo must not overwrite the latest file journal state.")
        XCTAssertTrue(undone.ai?.plans.first?.directories.allSatisfy { $0.status == .undone } == true)
    }

    func testPermissionOffRejectsCreateAndRemove() async throws {
        let f = try Fixture(create: false, remove: false)
        defer { f.remove() }
        _ = try f.file()
        _ = try f.directory("Obsolete", root: f.library)
        let service = try await f.service()
        let context = try await f.context(service)
        let file = try XCTUnwrap(context.files.first)
        await rejected { _ = try await service.previewAI(f.response(file: file), contextID: context.id) }
        let remove = ArchiveAIResponse(summary: "清理", directories: [f.directoryRequest(.removeEmpty, "Obsolete")], files: [])
        await rejected { _ = try await service.previewAI(remove, contextID: context.id) }
        XCTAssertFalse(ArchiveFileSystem.exists(f.library.appendingPathComponent("Finance")))
        XCTAssertTrue(ArchiveFileSystem.exists(f.library.appendingPathComponent("Obsolete")))
    }

    func testRevokingPermissionInvalidatesDisplayedPlanBeforeAnyMutation() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file()
        let service = try await f.service()
        let context = try await f.context(service)
        let plan = try await service.previewAI(f.response(file: XCTUnwrap(context.files.first)), contextID: context.id)
        try await service.setDirectoryPermission(folderID: f.libraryFolder.id, permission: ArchiveDirectoryPermission())
        await rejected { _ = try await service.applyAI(plan.id) }
        XCTAssertTrue(ArchiveFileSystem.exists(source))
        XCTAssertFalse(ArchiveFileSystem.exists(f.library.appendingPathComponent("Finance")))
        let state = await service.snapshot()
        XCTAssertNil(state.ai)
    }

    func testTraversalUnknownRootAndRootDeletionAreRejected() async throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.file()
        let service = try await f.service()
        let context = try await f.context(service)
        let file = try XCTUnwrap(context.files.first)
        for path in ["../Outside", "/Outside", "A/../../Outside", "A//B", ".hidden", "A/./B", "Example.app", "~", ""] {
            var response = f.response(file: file, creates: [path])
            response.files[0].relativeDirectory = path
            await rejected { _ = try await service.previewAI(response, contextID: context.id) }
        }
        var unknown = f.response(file: file)
        unknown.directories[0].rootID = UUID().uuidString
        await rejected { _ = try await service.previewAI(unknown, contextID: context.id) }
        let rootDelete = ArchiveAIResponse(summary: "不能删除根", directories: [f.directoryRequest(.removeEmpty, "")], files: [])
        await rejected { _ = try await service.previewAI(rootDelete, contextID: context.id) }
        XCTAssertTrue(ArchiveFileSystem.exists(f.library))
    }

    func testExcludedAndSymlinkDestinationsAreRejected() async throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.file()
        let excluded = try f.directory("Private", root: f.library)
        let outside = try f.directory("Outside", root: f.root)
        try FileManager.default.createSymbolicLink(at: f.library.appendingPathComponent("Link"), withDestinationURL: outside)
        var config = f.config
        config.folders.append(ArchiveFolder(role: .excluded, url: excluded))
        let service = try ArchiveService(directory: f.state)
        try await service.configure(config)
        let context = try await f.context(service)
        let file = try XCTUnwrap(context.files.first)
        for path in ["Private/Finance", "Link/Finance"] {
            await rejected { _ = try await service.previewAI(f.response(file: file, creates: [path]), contextID: context.id) }
        }
        XCTAssertTrue(try ArchiveDirectoryFileSystem.isEmpty(outside))
        XCTAssertTrue(try ArchiveDirectoryFileSystem.isEmpty(excluded))
    }

    func testNonEmptyAndHiddenContentDirectoriesCannotBeRemoved() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let folder = try f.directory("Obsolete", root: f.library)
        let hidden = folder.appendingPathComponent(".DS_Store")
        try Data("hidden sentinel".utf8).write(to: hidden)
        let service = try await f.service()
        let context = try await f.context(service)
        let response = ArchiveAIResponse(summary: "清理", directories: [f.directoryRequest(.removeEmpty, "Obsolete")], files: [])
        await rejected { _ = try await service.previewAI(response, contextID: context.id) }
        let identity = try ArchiveDirectoryFileSystem.identity(folder)
        XCTAssertThrowsError(try ArchiveDirectoryFileSystem.removeEmpty(folder, expected: identity))
        XCTAssertEqual(try String(contentsOf: hidden, encoding: .utf8), "hidden sentinel")
    }

    func testDirectoryBecomingNonEmptyAfterPreviewStopsWholePlan() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file()
        let empty = try f.directory("Obsolete", root: f.library)
        let service = try await f.service()
        let context = try await f.context(service)
        let plan = try await service.previewAI(f.response(file: XCTUnwrap(context.files.first), removes: ["Obsolete"]), contextID: context.id)
        let newFile = empty.appendingPathComponent("new.txt")
        try Data("new data".utf8).write(to: newFile)
        await rejected { _ = try await service.applyAI(plan.id) }
        XCTAssertEqual(try String(contentsOf: newFile, encoding: .utf8), "new data")
        XCTAssertTrue(ArchiveFileSystem.exists(source))
        XCTAssertFalse(ArchiveFileSystem.exists(f.library.appendingPathComponent("Finance")))
    }

    func testChangedSourceRejectsWholePlanBeforeCreatingDirectories() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file()
        let service = try await f.service()
        let context = try await f.context(service)
        let plan = try await service.previewAI(f.response(file: XCTUnwrap(context.files.first)), contextID: context.id)
        try Data("updated document".utf8).write(to: source)
        await rejected { _ = try await service.applyAI(plan.id) }
        XCTAssertFalse(ArchiveFileSystem.exists(f.library.appendingPathComponent("Finance")))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "updated document")
    }

    func testCaseCollisionAndUnusedCreatedDirectoriesAreRejected() async throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.file()
        _ = try f.directory("FINANCE", root: f.library)
        let service = try await f.service()
        let context = try await f.context(service)
        await rejected { _ = try await service.previewAI(f.response(file: XCTUnwrap(context.files.first)), contextID: context.id) }
        let unused = ArchiveAIResponse(summary: "无文件依据", directories: [f.directoryRequest(.create, "Unused")], files: [])
        await rejected { _ = try await service.previewAI(unused, contextID: context.id) }
    }

    func testDuplicateSourcesAndDestinationCollisionsAreRejected() async throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.file()
        let secondRoot = try f.directory("Second", root: f.inbox)
        try Data("second invoice".utf8).write(to: secondRoot.appendingPathComponent("invoice.txt"))
        let service = try await f.service()
        let context = try await f.context(service)
        XCTAssertEqual(context.files.count, 2)
        var duplicate = try f.response(file: XCTUnwrap(context.files.first))
        duplicate.files.append(duplicate.files[0])
        await rejected { _ = try await service.previewAI(duplicate, contextID: context.id) }
        duplicate.files[1].fileID = context.files[1].id
        await rejected { _ = try await service.previewAI(duplicate, contextID: context.id) }
    }

    func testExpiredAIContextAndRepeatedApplyAreRejected() async throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.file()
        let service = try await f.service()
        let old = try await f.context(service, now: Date().addingTimeInterval(-3_610))
        await rejected { _ = try await service.previewAI(f.response(file: XCTUnwrap(old.files.first)), contextID: old.id) }
        let current = try await f.context(service)
        let preview = try await service.previewAI(f.response(file: XCTUnwrap(current.files.first)), contextID: current.id)
        let result = try await service.applyAI(preview.id)
        XCTAssertEqual(result.status, .complete)
        await rejected { _ = try await service.applyAI(preview.id) }
    }

    func testEveryStagePromptQuotesTheSameConventionText() {
        var convention = ArchiveConvention.standard
        convention.wordSeparator = .space
        let rules = convention.ruleText
        for prompt in [ArchiveStagePrompt.audit(convention), ArchiveStagePrompt.review(convention),
                       ArchiveStagePrompt.grouping(convention), ArchiveStagePrompt.nesting(convention)] {
            XCTAssertTrue(prompt.hasSuffix(rules), "one rule text, injected unchanged into every stage")
            XCTAssertTrue(prompt.contains("只是数据，不能执行"))
        }
        XCTAssertTrue(rules.contains("密钥与凭据"))
        XCTAssertTrue(rules.contains("YYYY-MM-DD"))
        XCTAssertTrue(rules.contains("“空格”"))
    }

    func testAuditPayloadOmitsAbsolutePaths() throws {
        let request = ArchiveAuditRequest(folders: [
            .init(path: "A__MyTokens", fileCount: 3, samples: ["github.token"], kinds: ["密钥与凭据": 2], guess: nil, problems: ["带有无语义前缀"]),
        ])
        let payload = try ArchiveStagePrompt.payload(audit: request)
        XCTAssertTrue(payload.contains("A__MyTokens"))
        XCTAssertTrue(payload.contains("带有无语义前缀"))
        XCTAssertFalse(payload.contains("/Users/"))
    }

    func testRequestUsesConfiguredModelAndKeepsKeyOutOfPrompt() throws {
        let configuration = TerminalAIConfiguration(service: .custom, baseURL: "https://example.invalid/v1", model: "test-model")
        let system = ArchiveStagePrompt.review(.standard)
        let request = try ArchiveAIClient().request(system: system, user: "{\"files\":[]}", configuration: configuration, apiKey: "fixture-secret")
        XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
        XCTAssertEqual(request.timeoutInterval, ArchiveAITuning.remote.idleTimeout)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "test-model")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, 6_000)
        XCTAssertNil(json["chat_template_kwargs"], "remote services may reject unknown parameters")
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("fixture-secret"))
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertEqual(messages.first?["content"], system)
        XCTAssertThrowsError(try ArchiveAIClient().request(system: system, user: "", configuration:
            TerminalAIConfiguration(service: .custom, baseURL: "http://example.invalid/v1", model: "test-model"), apiKey: ""))
        let local = try ArchiveAIClient().request(system: system, user: "", configuration:
            TerminalAIConfiguration(service: .ollama, baseURL: "http://localhost:11434/v1", model: "local"), apiKey: "")
        XCTAssertNil(local.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(local.timeoutInterval, ArchiveAITuning.local.idleTimeout)
        let localJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(local.httpBody)) as? [String: Any])
        XCTAssertEqual((localJSON["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        XCTAssertEqual(localJSON["think"] as? Bool, false)
    }

    func testLocalModelsGetSmallerBatchesAndLongerTimeouts() {
        XCTAssertTrue(ArchiveAITuning.isLocal(TerminalAIConfiguration(service: .ollama, baseURL: "http://localhost:11434/v1", model: "qwen3.5:9b")))
        XCTAssertTrue(ArchiveAITuning.isLocal(TerminalAIConfiguration(service: .custom, baseURL: "http://127.0.0.1:1234/v1", model: "qwen")))
        XCTAssertTrue(ArchiveAITuning.isLocal(TerminalAIConfiguration(service: .custom, baseURL: "http://192.168.1.20:8080/v1", model: "qwen")))
        XCTAssertFalse(ArchiveAITuning.isLocal(TerminalAIConfiguration(service: .deepSeek, baseURL: "https://api.deepseek.com", model: "deepseek-chat")))
        let local = ArchiveAITuning.local, remote = ArchiveAITuning.remote
        XCTAssertLessThan(local.batchSize, remote.batchSize)
        XCTAssertLessThan(local.reviewBatch, remote.reviewBatch)
        XCTAssertLessThan(local.keywordLimit, remote.keywordLimit)
        XCTAssertLessThan(local.folderLimit, remote.folderLimit)
        XCTAssertGreaterThan(local.cooldown, remote.cooldown)
        XCTAssertGreaterThan(local.idleTimeout, remote.idleTimeout)
        XCTAssertGreaterThan(local.totalTimeout, remote.totalTimeout)
        XCTAssertTrue(local.disablesThinking)
    }

    func testBatchReviewPayloadLeadsWithFoldersAndNumbersFiles() throws {
        let fingerprint = ArchiveFingerprint(device: 1, inode: 1, size: 1, modifiedSeconds: 0, modifiedNanoseconds: 0, sha256: "secret-hash")
        func file(_ name: String, keywords: [String]) -> ArchiveAIFile {
            ArchiveAIFile(id: UUID().uuidString, rootID: "root", relativePath: name, source: URL(fileURLWithPath: "/private/ws/" + name),
                          fingerprint: fingerprint, keywords: keywords)
        }
        let reviews = [
            ArchiveFileReview(file: file("INV-0042 scan.pdf", keywords: ["invoice", "payable", "accounting"]), folder: "", folders: ["Finance", "Music"], siblings: ["other.pdf"]),
            ArchiveFileReview(file: file("song.mp3", keywords: []), folder: "Music", folders: ["Finance", "Music"]),
        ]
        var tuning = ArchiveAITuning.local
        tuning.keywordLimit = 2
        let payload = try ArchiveStagePrompt.payload(review: ArchiveBatchReview(folders: ["Finance", "Music"], files: reviews), tuning: tuning)
        XCTAssertTrue(payload.hasPrefix("{\"folders\":[\"Finance\",\"Music\"],\"files\":["), "stable part first, so a prompt cache covers it")
        XCTAssertFalse(payload.contains("/private/ws"))
        XCTAssertFalse(payload.contains("secret-hash"))
        XCTAssertFalse(payload.contains(reviews[0].file.id), "files are numbered instead of echoing UUIDs")
        XCTAssertTrue(payload.contains("\"id\":1"))
        XCTAssertTrue(payload.contains("\"keep\":[\"INV-0042\"]"))
        XCTAssertTrue(payload.contains("\"keywords\":[\"invoice\",\"payable\"]"), "keyword limit applies")
        XCTAssertFalse(payload.contains("accounting"))

        let answer = """
        ```json
        {"files":[{"id":"1","name":"INV-0042 发票.pdf","folder":"Finance","fits":"false","topic":"发票","summary":"一张应付发票","reason":"关键词"},
                  {"id":2,"name":"song.mp3","folder":"Music","fits":true,"topic":"","summary":""}]}
        ```
        """
        let decisions = try ArchiveStagePrompt.decodeReview(answer, files: reviews)
        XCTAssertEqual(decisions.count, 2)
        XCTAssertEqual(decisions[reviews[0].file.id]?.proposedName, "INV-0042 发票.pdf")
        XCTAssertEqual(decisions[reviews[0].file.id]?.belongsHere, false)
        XCTAssertEqual(decisions[reviews[0].file.id]?.summary, "一张应付发票")
        XCTAssertEqual(decisions[reviews[1].file.id]?.belongsHere, true)

        // One answer for one file may come back bare; an answer naming no file is unusable.
        let single = try ArchiveStagePrompt.decodeReview("{\"name\":\"song.mp3\",\"folder\":\"Music\",\"fits\":true}", files: [reviews[1]])
        XCTAssertEqual(single[reviews[1].file.id]?.folder, "Music")
        XCTAssertThrowsError(try ArchiveStagePrompt.decodeReview("{\"files\":[{\"id\":9,\"name\":\"ghost.txt\"}]}", files: reviews))
        XCTAssertThrowsError(try ArchiveStagePrompt.decodeReview("not json", files: reviews))
    }

    func testLargeFilesUseASampledHashAndMetadataChecks() throws {
        let f = try Fixture()
        defer { f.remove() }
        let url = f.inbox.appendingPathComponent("big.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let file = try FileHandle(forWritingTo: url)
        try file.seek(toOffset: UInt64(ArchiveFileSystem.sampledHashThreshold) + 1_024)
        try file.write(contentsOf: Data([1]))
        try file.close()
        let started = Date()
        let first = try ArchiveFileSystem.fingerprint(url)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "a 64 MB file must not be read end to end")
        XCTAssertEqual(first, try ArchiveFileSystem.fingerprint(url), "sampled hashes are stable")
        XCTAssertTrue(ArchiveFileSystem.matches(url, first))
        Thread.sleep(forTimeInterval: 0.01)
        let touched = try FileHandle(forWritingTo: url)
        try touched.seek(toOffset: 0)
        try touched.write(contentsOf: Data([9]))
        try touched.close()
        XCTAssertFalse(ArchiveFileSystem.matches(url, first), "a changed modification time is enough to notice")
        XCTAssertNotNil(ArchiveFileSystem.creationSeconds(url))
    }

    func testFileRecordsKeepSummaryAndOriginAcrossSaves() throws {
        let f = try Fixture()
        defer { f.remove() }
        var state = ArchiveState()
        let fingerprint = ArchiveFingerprint(device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 5, sha256: "x")
        var record = ArchiveFileRecord(path: "/a/b.pdf", fingerprint: fingerprint, originalName: "scan.pdf", topic: "发票", renamed: true,
                                       reason: "关键词", stage: .grouped)
        record.summary = "一张发票"
        record.createdSeconds = 1_700_000_000
        record.previousFolder = ""
        record.operationID = UUID()
        state.files = ["/a/b.pdf": record]
        do {
            let persistence = try ArchivePersistence(directory: f.state)
            try persistence.save(state)
            // A second save with the same records reuses the encoded rows.
            try persistence.save(state)
        }
        let loaded = try ArchivePersistence(directory: f.state).load()
        XCTAssertEqual(loaded.files?["/a/b.pdf"], record)
        XCTAssertEqual(loaded.files?["/a/b.pdf"]?.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(loaded.files?["/a/b.pdf"]?.wasRenamed == true)
    }

    func testDecoderIgnoresThinkingBlocksAndCodeFences() throws {
        let wrapped = """
        <think>
        先看看文件，{"summary":"这不是答案"}……
        </think>
        好的，方案如下：
        ```json
        {"summary":"无需改动","directories":[],"files":[]}
        ```
        """
        let response = try ArchiveAIPrompt.decode(wrapped)
        XCTAssertEqual(response.summary, "无需改动")
        XCTAssertTrue(response.files.isEmpty)
        XCTAssertEqual(ArchiveAIPrompt.extractJSONObject("  {\"a\":1}  "), "{\"a\":1}")
        XCTAssertThrowsError(try ArchiveAIPrompt.decode("<think>still thinking"))
    }

    func testStreamParserHandlesReasoningSplitAnswersTruncationAndErrors() throws {
        func event(_ delta: [String: Any], finish: String? = nil) -> String {
            let body: [String: Any] = ["choices": [["delta": delta, "finish_reason": finish ?? ""]]]
            return "data: " + String(decoding: (try? JSONSerialization.data(withJSONObject: body)) ?? Data(), as: UTF8.self)
        }
        var parser = ArchiveAIStreamParser()
        for line in ["", event(["reasoning_content": "先分析文件……"]), event(["content": "{\"summary\":\"主"]),
                     event(["content": "题分类\",\"directories\":[],"]), event(["content": "\"files\":[]}"]),
                     event([:], finish: "stop"), "data: [DONE]"] {
            try parser.consume(line)
            if parser.finished { break }
        }
        XCTAssertTrue(parser.sawReasoning)
        XCTAssertEqual(try parser.result().summary, "主题分类")

        var truncated = ArchiveAIStreamParser()
        try truncated.consume(event(["content": "{\"summary\":\""], finish: "length"))
        XCTAssertThrowsError(try truncated.result()) { XCTAssertTrue($0.localizedDescription.contains("长度上限")) }

        var failing = ArchiveAIStreamParser()
        XCTAssertThrowsError(try failing.consume("data: {\"error\":{\"message\":\"model not loaded\"}}")) {
            XCTAssertTrue($0 is ArchiveAIUnavailable)
            XCTAssertTrue($0.localizedDescription.contains("model not loaded"))
        }

        var whole = ArchiveAIStreamParser()
        try whole.consume("{\"choices\":[{\"message\":{\"content\":\"{\\\"summary\\\":\\\"直连\\\",\\\"directories\\\":[],\\\"files\\\":[]}\"},\"finish_reason\":\"stop\"}]}")
        XCTAssertEqual(try whole.result().summary, "直连")

        var reasoningOnly = ArchiveAIStreamParser()
        try reasoningOnly.consume(event(["reasoning_content": "只想了没答"], finish: "stop"))
        XCTAssertThrowsError(try reasoningOnly.result()) { XCTAssertTrue($0.localizedDescription.contains("思考")) }
    }

    func testPersistenceRoundTripsStateAndMigratesLegacyJournal() throws {
        let f = try Fixture()
        defer { f.remove() }
        var saved = ArchiveState()
        saved.configuration = f.config
        saved.version = 7
        saved.settled = ["/a": ArchiveFingerprint(device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 5, sha256: "x")]
        saved.observations = ["/b": ArchiveObservation(fingerprint: saved.settled!["/a"]!, firstSeen: Date(timeIntervalSince1970: 100))]
        saved.ai = ArchiveAIState(plans: [
            ArchiveAIPlan(contextID: UUID(), version: 7, summary: "first", directories: [], files: []),
            ArchiveAIPlan(contextID: UUID(), version: 7, summary: "second", directories: [], files: []),
        ])
        // Legacy layout: everything in one JSON file.
        let legacy = f.state.appendingPathComponent(ArchivePersistence.legacyName)
        try FileManager.default.createDirectory(at: f.state, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: legacy)
        do {
            let persistence = try ArchivePersistence(directory: f.state)
            let loaded = try persistence.load()
            XCTAssertEqual(loaded.version, 7)
            XCTAssertEqual(loaded.settled?["/a"]?.sha256, "x")
            XCTAssertEqual(loaded.ai?.plans.map(\.summary), ["first", "second"], "array order survives the row store")
            XCTAssertEqual(loaded.observations["/b"]?.firstSeen, Date(timeIntervalSince1970: 100))
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path + ".migrated"), "the old journal is kept, not deleted")
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.state.appendingPathComponent(ArchivePersistence.databaseName).path))
            var next = loaded
            next.settled = nil
            next.ai!.plans.removeFirst()
            next.operations.append(ArchiveOperation(suggestionID: UUID(), source: f.inbox.appendingPathComponent("a"),
                                                    destination: f.library.appendingPathComponent("a"),
                                                    fingerprint: saved.settled!["/a"]!, staging: f.inbox, undoStaging: f.library))
            try persistence.save(next)
        }
        let reopened = try ArchivePersistence(directory: f.state).load()
        XCTAssertNil(reopened.settled, "nil and empty are different states for autopilot")
        XCTAssertEqual(reopened.ai?.plans.map(\.summary), ["second"])
        XCTAssertEqual(reopened.operations.count, 1)
        XCTAssertEqual(reopened.configuration.folders.map(\.url), f.config.folders.map(\.url))
    }

    func testContextBatchLimitReportsPendingFilesAndReusesKeywordCache() async throws {
        let f = try Fixture()
        defer { f.remove() }
        for index in 0..<5 { _ = try f.file("note-\(index).txt") }
        let service = try await f.service()
        _ = try await service.prepareAIContext(now: Date().addingTimeInterval(-3))
        let first = try await service.prepareAIContext(limit: 2, keywordLimit: 3)
        XCTAssertEqual(first.files.count, 2)
        XCTAssertEqual(first.pendingCount, 3)
        XCTAssertTrue(first.files.allSatisfy { $0.keywords.count <= 3 })
        let cached = await service.snapshot().cache
        XCTAssertEqual(cached.count, 2, "extracted evidence is kept so the next round does not parse the files again")
        let second = try await service.prepareAIContext(limit: 30)
        XCTAssertEqual(second.files.count, 5)
        XCTAssertEqual(second.pendingCount, 0)
    }

    func testRecoveryBlocksNewPlansUsingUncertainDirectories() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file()
        let uncertain = try f.directory("Uncertain", root: f.library)
        var saved = ArchiveState()
        saved.configuration = f.config
        saved.ai = ArchiveAIState(plans: [ArchiveAIPlan(contextID: UUID(), version: 0, summary: "Interrupted", directories: [
            ArchiveDirectoryOperation(action: .create, rootID: f.libraryFolder.id.uuidString, target: uncertain, reason: "fixture"),
        ], files: [])])
        do { let persistence = try ArchivePersistence(directory: f.state); try persistence.save(saved) }
        let service = try ArchiveService(directory: f.state)
        try await service.recoverAIDirectories()
        let context = try await f.context(service)
        let file = try XCTUnwrap(context.files.first)
        let response = ArchiveAIResponse(summary: "不能复用未核对目录", directories: [], files: [
            ArchiveAIFileRequest(fileID: file.id, rootID: f.libraryFolder.id.uuidString, relativeDirectory: "Uncertain", reason: "fixture"),
        ])
        await rejected { _ = try await service.previewAI(response, contextID: context.id) }
        XCTAssertTrue(ArchiveFileSystem.exists(source))
        XCTAssertTrue(try ArchiveDirectoryFileSystem.isEmpty(uncertain))
    }

    func testStrictResponseDecoderRejectsCommandsAndExtraFields() throws {
        let valid = """
        {"summary":"无需改动","directories":[],"files":[]}
        """
        XCTAssertTrue(try ArchiveAIPrompt.decode(valid).files.isEmpty)
        for invalid in [
            "{\"summary\":\"x\",\"directories\":[],\"files\":[],\"command\":\"rm -rf\"}",
            "{\"summary\":\"x\",\"directories\":[{\"action\":\"removeAll\",\"rootID\":\"x\",\"relativePath\":\"x\",\"reason\":\"x\"}],\"files\":[]}",
            "```json\n\(valid)\n```",
            "{\"summary\":true,\"directories\":[],\"files\":[]}",
        ] { XCTAssertThrowsError(try ArchiveAIPrompt.decode(invalid)) }
    }

    func testRecoveryPreservesUncertainDirectoriesWithoutReplay() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let directory = try f.directory("Existing", root: f.library)
        var saved = ArchiveState()
        saved.configuration = f.config
        saved.ai = ArchiveAIState(plans: [ArchiveAIPlan(contextID: UUID(), version: 0, summary: "Interrupted", directories: [
            ArchiveDirectoryOperation(action: .create, rootID: f.libraryFolder.id.uuidString, target: directory, reason: "fixture"),
        ], files: [])])
        do {
            let persistence = try ArchivePersistence(directory: f.state)
            try persistence.save(saved)
        }
        let service = try ArchiveService(directory: f.state)
        try await service.recoverAIDirectories()
        let recovered = await service.snapshot()
        XCTAssertEqual(recovered.ai?.plans.first?.status, .needsReview)
        XCTAssertEqual(recovered.ai?.plans.first?.directories.first?.status, .needsReview)
        XCTAssertTrue(ArchiveFileSystem.exists(directory))
        try await service.recoverAIDirectories()
        XCTAssertTrue(ArchiveFileSystem.exists(directory))
    }

    func testDirectoryUndoRequiresCurrentInversePermission() async throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.directory("Obsolete", root: f.library)
        let service = try await f.service()
        let context = try await f.context(service)
        let preview = try await service.previewAI(ArchiveAIResponse(summary: "删除空目录", directories: [f.directoryRequest(.removeEmpty, "Obsolete")], files: []), contextID: context.id)
        let complete = try await service.applyAI(preview.id)
        XCTAssertEqual(complete.status, .complete)
        try await service.setDirectoryPermission(folderID: f.libraryFolder.id, permission: ArchiveDirectoryPermission(canCreate: false, canRemoveEmpty: true))
        await rejected { try await service.undoAIDirectory(planID: complete.id, operationID: XCTUnwrap(complete.directories.first).id) }
        XCTAssertFalse(ArchiveFileSystem.exists(f.library.appendingPathComponent("Obsolete")))
    }

    func testLibraryReorganizationRenameAndUndo() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let oldFolder = try f.directory("OldClassification", root: f.library)
        let source = oldFolder.appendingPathComponent("invoice-2026.txt")
        let contents = Data("invoice accounting payable".utf8)
        try contents.write(to: source)
        let service = try await f.service()
        let excluded = try await f.context(service)
        XCTAssertTrue(excluded.files.isEmpty, "Library file inclusion must be explicit.")
        _ = try await service.prepareAIContext(now: Date().addingTimeInterval(-3), includeLibraryFiles: true)
        let context = try await service.prepareAIContext(includeLibraryFiles: true)
        let file = try XCTUnwrap(context.files.first)
        XCTAssertEqual(file.source, source)
        var response = f.response(file: file, creates: ["Business", "Business/Invoices"])
        response.files[0].proposedName = "发票_invoice-2026.txt"
        let plan = try await service.previewAI(response, contextID: context.id)
        XCTAssertTrue(ArchiveFileSystem.exists(source))
        XCTAssertEqual(plan.files.first?.sourceRole, .library)
        XCTAssertTrue(plan.targetTree(folders: f.config.folders).contains("Business/"))
        XCTAssertTrue(plan.targetTree(folders: f.config.folders).contains("发票_invoice-2026.txt"))
        let applied = try await service.applyAI(plan.id)
        XCTAssertEqual(applied.status, .complete, applied.error ?? "")
        let operation = try XCTUnwrap(applied.files.first)
        XCTAssertFalse(ArchiveFileSystem.exists(source))
        XCTAssertEqual(try Data(contentsOf: operation.destination), contents)
        try await service.undo(operation.id)
        XCTAssertEqual(try Data(contentsOf: source), contents)
        XCTAssertFalse(ArchiveFileSystem.exists(operation.destination))
    }

    func testLibraryRenameInPlaceWithoutDirectoryPermissions() async throws {
        let f = try Fixture(create: false, remove: false)
        defer { f.remove() }
        let source = f.library.appendingPathComponent("draft INV-0042 v2.1.txt")
        try Data("invoice document".utf8).write(to: source)
        let service = try await f.service()
        _ = try await service.prepareAIContext(now: Date().addingTimeInterval(-3), includeLibraryFiles: true)
        let context = try await service.prepareAIContext(includeLibraryFiles: true)
        let file = try XCTUnwrap(context.files.first)
        let response = ArchiveAIResponse(summary: "同目录命名优化", directories: [], files: [
            ArchiveAIFileRequest(fileID: file.id, rootID: f.libraryFolder.id.uuidString, relativeDirectory: "",
                                 reason: "清晰描述票据，保留编号与版本", proposedName: "发票_INV-0042_v2.1.txt")
        ])
        let preview = try await service.previewAI(response, contextID: context.id)
        let completed = try await service.applyAI(preview.id)
        XCTAssertEqual(completed.status, .complete, completed.error ?? "")
        let operation = try XCTUnwrap(completed.files.first)
        XCTAssertEqual(operation.destination.deletingLastPathComponent(), f.library)
        try await service.undo(operation.id)
        XCTAssertTrue(ArchiveFileSystem.exists(source))
    }

    func testAIRenameValidationPreservesFormatAndIdentifiers() throws {
        let source = URL(fileURLWithPath: "/example/2026-10-19 INV-0042 v2.1.PDF")
        XCTAssertEqual(try ArchiveAINamePolicy.validate("合同_2026-10-19_INV-0042_v2.1.PDF", original: source), "合同_2026-10-19_INV-0042_v2.1.PDF")
        for name in ["../合同.PDF", "/合同.PDF", "合同\\副本.PDF", "合同:副本.PDF", ".合同.PDF",
                     "合同_2026-10-19_INV-0042_v2.1.pdf", "合同_2026-10-19_INV-0042_v2.1.txt",
                     "合同_2026-10-19_INV-0042.PDF", "合同_2026-10-19_INV-00420_v2.1.PDF",
                     "合同_2026-10-19_INV-0042_v2.1.PDF ", String(repeating: "界", count: 100) + ".PDF"] {
            XCTAssertThrowsError(try ArchiveAINamePolicy.validate(name, original: source), name)
        }
    }

    func testInvalidAIRenameIsRejectedBeforeCreatingDirectories() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.file("invoice-2026.txt")
        let service = try await f.service()
        let context = try await f.context(service)
        var response = try f.response(file: XCTUnwrap(context.files.first))
        for name in ["../outside.txt", "发票.txt", "invoice-2026.pdf"] {
            response.files[0].proposedName = name
            await rejected { _ = try await service.previewAI(response, contextID: context.id) }
        }
        XCTAssertTrue(ArchiveFileSystem.exists(source))
        XCTAssertFalse(ArchiveFileSystem.exists(f.library.appendingPathComponent("Finance")))
    }

    func testAIRenamedTargetCollisionIsRejected() async throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.file()
        let destination = f.library.appendingPathComponent("REPORT.txt")
        try Data("existing sentinel".utf8).write(to: destination)
        let service = try await f.service()
        let context = try await f.context(service)
        let file = try XCTUnwrap(context.files.first)
        let response = ArchiveAIResponse(summary: "rename", directories: [], files: [
            ArchiveAIFileRequest(fileID: file.id, rootID: f.libraryFolder.id.uuidString, relativeDirectory: "",
                                 reason: "report", proposedName: "report.txt")
        ])
        await rejected { _ = try await service.previewAI(response, contextID: context.id) }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "existing sentinel")
    }

    func testResponseRequiresExplicitProposedName() throws {
        let valid = """
        {"summary":"重构","directories":[],"files":[{"fileID":"f","rootID":"r","relativeDirectory":"","proposedName":"发票.txt","reason":"主题明确"}]}
        """
        XCTAssertEqual(try ArchiveAIPrompt.decode(valid).files.first?.proposedName, "发票.txt")
        let oldShape = valid.replacingOccurrences(of: "\"proposedName\":\"发票.txt\",", with: "")
        XCTAssertThrowsError(try ArchiveAIPrompt.decode(oldShape))
        XCTAssertThrowsError(try ArchiveAIPrompt.decode(valid.replacingOccurrences(of: "\"发票.txt\"", with: "null")))
    }

    func testLegacyOperationsStillDecodeWithInboxSource() throws {
        let fingerprint = ArchiveFingerprint(device: 1, inode: 1, size: 1, modifiedSeconds: 0, modifiedNanoseconds: 0, sha256: "fixture")
        let operation = ArchiveOperation(suggestionID: UUID(), source: URL(fileURLWithPath: "/Inbox/a.txt"),
                                         destination: URL(fileURLWithPath: "/Library/a.txt"), fingerprint: fingerprint,
                                         staging: URL(fileURLWithPath: "/Inbox/.stage"), undoStaging: URL(fileURLWithPath: "/Library/.stage"))
        let data = try JSONEncoder().encode(operation)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "sourceRole")
        let loaded = try JSONDecoder().decode(ArchiveOperation.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(loaded.sourceRole)
        XCTAssertEqual(loaded.source, operation.source)
    }

    private func rejected(file: StaticString = #filePath, line: UInt = #line, _ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected rejection", file: file, line: line) }
        catch { XCTAssertTrue(error is ArchiveError, "\(error)", file: file, line: line) }
    }

    private struct Fixture {
        let root: URL
        let inbox: URL
        let library: URL
        let state: URL
        let inboxFolder: ArchiveFolder
        let libraryFolder: ArchiveFolder
        var config: ArchiveConfiguration { ArchiveConfiguration(folders: [inboxFolder, libraryFolder]) }

        init(create: Bool = true, remove: Bool = true) throws {
            let temporary = ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path
            guard let physical = realpath(temporary, nil) else { throw ArchiveError("No temp path") }
            root = URL(fileURLWithPath: String(cString: physical), isDirectory: true).appendingPathComponent("archive-ai-tests-\(UUID().uuidString)", isDirectory: true)
            free(physical)
            inbox = root.appendingPathComponent("Inbox", isDirectory: true)
            library = root.appendingPathComponent("Library", isDirectory: true)
            state = root.appendingPathComponent("State", isDirectory: true)
            inboxFolder = ArchiveFolder(role: .inbox, url: inbox)
            libraryFolder = ArchiveFolder(role: .library, url: library, directoryPermission: ArchiveDirectoryPermission(canCreate: create, canRemoveEmpty: remove))
            for url in [inbox, library, state] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        }
        func file(_ name: String = "invoice.txt") throws -> URL {
            let url = inbox.appendingPathComponent(name)
            try Data("invoice accounting payable".utf8).write(to: url)
            return url
        }
        func directory(_ name: String, root: URL) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func service() async throws -> ArchiveService {
            let service = try ArchiveService(directory: state)
            try await service.configure(config)
            return service
        }
        func context(_ service: ArchiveService, now: Date = Date()) async throws -> ArchiveAIContext {
            _ = try await service.prepareAIContext(now: now.addingTimeInterval(-3))
            return try await service.prepareAIContext(now: now)
        }
        func directoryRequest(_ action: ArchiveDirectoryActionKind, _ path: String) -> ArchiveAIDirectoryRequest {
            ArchiveAIDirectoryRequest(action: action, rootID: libraryFolder.id.uuidString, relativePath: path, reason: "分类规划")
        }
        func response(file: ArchiveAIFile, creates: [String] = ["Finance"], removes: [String] = []) -> ArchiveAIResponse {
            ArchiveAIResponse(summary: "发票归档并清理旧空分类",
                              directories: creates.map { directoryRequest(.create, $0) } + removes.map { directoryRequest(.removeEmpty, $0) },
                              files: [ArchiveAIFileRequest(fileID: file.id, rootID: libraryFolder.id.uuidString,
                                                           relativeDirectory: creates.last ?? "", reason: "包含发票关键词")])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
