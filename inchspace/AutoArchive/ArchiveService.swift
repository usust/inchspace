import Darwin
import Foundation

actor ArchiveService {
    let persistence: ArchivePersistence
    private(set) var state: ArchiveState
    var aiContext: ArchiveAIContext?
    var aiPreview: ArchiveAIPlan?

    init(directory: URL = ArchivePersistence.defaultDirectory) throws {
        let persistence = try ArchivePersistence(directory: directory)
        self.persistence = persistence
        state = try persistence.load()
    }

    func snapshot() -> ArchiveState { state }

    func configure(_ configuration: ArchiveConfiguration) throws {
        let changed = configuration.folders.filter { folder in
            !state.configuration.folders.contains {
                $0.id == folder.id && $0.role == folder.role && $0.url == folder.url && $0.bookmark == folder.bookmark
            }
        }
        // Configuration editing must remain possible when an old volume or bookmark is unavailable.
        try withAccess(ArchiveConfiguration(folders: changed)) { accessible in
            if !configuration.inboxes.isEmpty && !configuration.libraries.isEmpty {
                try ArchiveFileSystem.validateConfiguration(configuration, stateDirectory: persistence.directory,
                                                              requiresDirectoryAccess: false)
            }
            for folder in accessible.folders where folder.role != .excluded {
                let fd = try ArchiveFileSystem.openDirectory(folder.url)
                Darwin.close(fd)
                try ArchiveFileSystem.checkProtectedAncestors(folder.url)
            }
            var next = state
            next.configuration = configuration
            next.version += 1
            next.rules = []
            next.report = nil
            next.observations = [:]
            next.cache = [:]
            next.settled = nil
            for index in next.suggestions.indices where next.suggestions[index].status == .pending {
                next.suggestions[index].status = .stale
            }
            try commit(next)
        }
    }

    func learn() throws -> [String] {
        try withAccess(state.configuration) { config in
            try ArchiveFileSystem.validateConfiguration(config, stateDirectory: persistence.directory)
            let scan = try ArchiveFileSystem.scan(config, role: .library)
            let selected = ArchiveLearning.sample(scan.files, limit: config.sampleLimit)
            var next = state
            var samples: [ArchiveEvidence] = []
            var hits = 0
            var warnings = scan.warnings
            for file in selected {
                try Task.checkCancellation()
                do {
                    if let cached = next.cache[file.url.path], cached.fingerprint == file.fingerprint {
                        samples.append(cached)
                        hits += 1
                    } else {
                        let sample = try ArchiveLearning.extract(file, maxBytes: config.maxFileBytes)
                        samples.append(sample)
                        next.cache[file.url.path] = sample
                    }
                } catch { warnings.append("跳过 \(file.url.lastPathComponent)：\(error.localizedDescription)") }
            }
            let (rules, heldOut) = ArchiveLearning.rules(from: samples, previous: next.rules)
            next.rules = rules
            next.version += 1
            for index in next.suggestions.indices where next.suggestions[index].status == .pending {
                next.suggestions[index].status = .stale
            }
            let consistent = heldOut.filter { sample in
                ArchiveLearning.rank(rules, words: ArchiveLearning.tokens(sample.url.deletingPathExtension().lastPathComponent))
                    .first?.rule.directory == sample.url.deletingLastPathComponent()
            }.count
            next.report = ArchiveLearningReport(sampled: samples.count,
                                                extractionFailures: samples.filter { $0.extractionNote != nil }.count,
                                                cached: hits, heldOut: heldOut.count, consistent: consistent)
            trimCache(&next)
            try commit(next)
            return warnings
        }
    }

    func suggest(now: Date = Date()) throws -> [String] {
        try withAccess(state.configuration) { config in
            try ArchiveFileSystem.validateConfiguration(config, stateDirectory: persistence.directory)
            guard !state.rules.isEmpty else { throw ArchiveError("请先学习归档资料库。每个分类建议准备至少两个有代表性的样本。") }
            let scan = try ArchiveFileSystem.scan(config, role: .inbox)
            var next = state
            var warnings = scan.warnings
            for index in next.suggestions.indices where next.suggestions[index].status == .pending {
                let item = next.suggestions[index]
                if item.version != next.version || now.timeIntervalSince(item.createdAt) > 86_400 ||
                    !scan.files.contains(where: { $0.url == item.source && $0.fingerprint == item.fingerprint }) {
                    next.suggestions[index].status = .stale
                }
            }
            let paths = Set(scan.files.map { $0.url.path })
            next.observations = next.observations.filter { paths.contains($0.key) }
            for file in scan.files {
                try Task.checkCancellation()
                let observed = next.observations[file.url.path]
                if observed?.fingerprint != file.fingerprint {
                    next.observations[file.url.path] = ArchiveObservation(fingerprint: file.fingerprint, firstSeen: now)
                    if config.stableSeconds > 0 { continue }
                } else if let observed, now.timeIntervalSince(observed.firstSeen) < config.stableSeconds { continue }
                if next.suggestions.contains(where: {
                    $0.source == file.url && $0.fingerprint == file.fingerprint && $0.version == next.version &&
                    ($0.status == .pending || $0.status == .skipped)
                }) { continue }
                // An unresolved journal entry owns its source until recovery has reconciled it.
                if next.operations.contains(where: { $0.source == file.url && [.planned, .undoPlanned, .needsReview].contains($0.status) }) { continue }
                do {
                    let sample: ArchiveEvidence
                    if let cached = next.cache[file.url.path], cached.fingerprint == file.fingerprint { sample = cached }
                    else {
                        sample = try ArchiveLearning.extract(file, maxBytes: config.maxFileBytes)
                        next.cache[file.url.path] = sample
                    }
                    let ranked = ArchiveLearning.rank(next.rules, words: Set(sample.words))
                    let unique = !ranked.isEmpty && (ranked.count == 1 || ranked[0].score > ranked[1].score)
                    let winner = unique ? ranked.first?.rule : nil
                    let executable = winner.map { $0.evidence.count >= 2 } ?? false
                    let reason: String
                    if let winner {
                        let matches = Set(sample.words).intersection(winner.aliases + winner.keywords).sorted().joined(separator: "、")
                        reason = executable ? "唯一匹配「\(winner.title)」，共同词：\(matches)；\(winner.evidence.count) 个历史样本。" : "「\(winner.title)」的训练样本不足两个，请补充资料后重新学习。"
                    } else { reason = ranked.isEmpty ? "未找到匹配分类，请人工整理或补充历史样本。" : "多个分类得分相同，需人工判断。" }
                    next.suggestions.append(ArchiveSuggestion(source: file.url, fingerprint: file.fingerprint,
                                                              directory: winner?.directory,
                                                              proposedName: try ArchiveFileSystem.normalizedName(file.url.lastPathComponent),
                                                              reason: reason, executable: executable,
                                                              extractionNote: sample.extractionNote, version: next.version,
                                                              createdAt: now))
                } catch { warnings.append("跳过 \(file.url.lastPathComponent)：\(error.localizedDescription)") }
            }
            trimCache(&next)
            try commit(next)
            return warnings
        }
    }

    func confirmRule(_ id: String) throws {
        var next = state
        guard let index = next.rules.firstIndex(where: { $0.id == id }) else { throw ArchiveError("规则不存在。") }
        next.rules[index].confirmed = true
        try commit(next)
    }

    func skip(_ ids: Set<UUID>) throws {
        var next = state
        for index in next.suggestions.indices where ids.contains(next.suggestions[index].id) && next.suggestions[index].status == .pending {
            next.suggestions[index].status = .skipped
        }
        try commit(next)
    }

    func preview(_ ids: Set<UUID>, mode: ArchiveApplyMode) throws -> [ArchiveOperation] {
        try withAccess(state.configuration) { config in try plans(ids, mode: mode, config: config) }
    }

    func apply(_ ids: Set<UUID>, mode: ArchiveApplyMode) throws -> [ArchiveOperation] {
        try withAccess(state.configuration) { config in
            let operations = try plans(ids, mode: mode, config: config)
            var next = state
            next.operations += operations
            // All plans reach disk before the first file is touched.
            try commit(next)
            for operation in operations {
                guard let index = state.operations.firstIndex(where: { $0.id == operation.id }) else { continue }
                var updated = state
                do {
                    _ = try plans([operation.suggestionID], mode: mode, config: config, allowedOperationID: operation.id)
                    try ArchiveFileSystem.move(source: operation.source, target: operation.destination,
                                               staging: operation.staging, expected: operation.fingerprint,
                                               maxBytes: config.maxFileBytes)
                    updated.operations[index].status = .complete
                    if let suggestion = updated.suggestions.firstIndex(where: { $0.id == operation.suggestionID }) {
                        updated.suggestions[suggestion].status = .applied
                    }
                } catch {
                    updated.operations[index].status = .needsReview
                    updated.operations[index].error = error.localizedDescription
                }
                // A persistence failure stops the batch; recovery uses the already durable plans.
                try commit(updated)
            }
            return state.operations.filter { item in operations.contains { $0.id == item.id } }
        }
    }

    func undo(_ id: UUID) throws {
        try withAccess(state.configuration) { config in
            guard let index = state.operations.firstIndex(where: { $0.id == id }), state.operations[index].status == .complete else {
                throw ArchiveError("仅能撤销已完成的归档操作。")
            }
            let operation = state.operations[index]
            try checkOperationScope(operation, config: config)
            try ArchiveFileSystem.validateMove(source: operation.destination, target: operation.source,
                                               expected: operation.fingerprint, maxBytes: config.maxFileBytes)
            var next = state
            next.operations[index].status = .undoPlanned
            next.operations[index].undoRequested = true
            try commit(next)
            do {
                try ArchiveFileSystem.move(source: operation.destination, target: operation.source,
                                           staging: operation.undoStaging, expected: operation.fingerprint,
                                           maxBytes: config.maxFileBytes)
            } catch {
                var failed = state
                let unchanged = (try? ArchiveFileSystem.fingerprint(operation.destination, maxBytes: config.maxFileBytes)) == operation.fingerprint
                failed.operations[index].status = unchanged && !ArchiveFileSystem.exists(operation.undoStaging) ? .complete : .needsReview
                if failed.operations[index].status == .complete { failed.operations[index].undoRequested = false }
                failed.operations[index].error = error.localizedDescription
                try commit(failed)
                throw error
            }
            var completed = state
            completed.operations[index].status = .undone
            completed.operations[index].error = nil
            // The explicit accepted feedback remains; do not immediately suggest the undone file again.
            if let suggestion = completed.suggestions.firstIndex(where: { $0.id == operation.suggestionID }) {
                completed.suggestions[suggestion].status = .skipped
            }
            try commit(completed)
        }
    }

    func recover() throws {
        try withAccess(state.configuration) { config in
            var next = state
            for index in next.operations.indices where [.planned, .undoPlanned, .needsReview].contains(next.operations[index].status) {
                let operation = next.operations[index]
                do {
                    try checkOperationScope(operation, config: config)
                    let staged = [operation.staging, operation.undoStaging].filter(ArchiveFileSystem.exists)
                    if !staged.isEmpty {
                        throw ArchiveError("暂存文件已保留，请在 Finder 中人工检查：\(staged.map(\.path).joined(separator: "；"))")
                    }
                    let sourceMatches = (try? ArchiveFileSystem.fingerprint(operation.source, maxBytes: config.maxFileBytes)) == operation.fingerprint
                    let targetMatches = (try? ArchiveFileSystem.fingerprint(operation.destination, maxBytes: config.maxFileBytes)) == operation.fingerprint
                    if targetMatches && !ArchiveFileSystem.exists(operation.source) {
                        next.operations[index].status = .complete
                        next.operations[index].undoRequested = false
                        if let suggestion = next.suggestions.firstIndex(where: { $0.id == operation.suggestionID }) { next.suggestions[suggestion].status = .applied }
                    } else if sourceMatches && !ArchiveFileSystem.exists(operation.destination) {
                        let undone = operation.undoRequested || operation.status == .undoPlanned
                        next.operations[index].status = undone ? .undone : .notExecuted
                        if undone, let suggestion = next.suggestions.firstIndex(where: { $0.id == operation.suggestionID }) {
                            next.suggestions[suggestion].status = .skipped
                        }
                    } else { throw ArchiveError("无法确定文件状态，请核对原位置、目标位置及内容。") }
                    next.operations[index].error = nil
                } catch {
                    next.operations[index].status = .needsReview
                    next.operations[index].error = error.localizedDescription
                }
            }
            try commit(next)
        }
    }

    private func plans(_ ids: Set<UUID>, mode: ArchiveApplyMode, config: ArchiveConfiguration, allowedOperationID: UUID? = nil) throws -> [ArchiveOperation] {
        try ArchiveFileSystem.validateConfiguration(config, stateDirectory: persistence.directory)
        guard !ids.isEmpty else { throw ArchiveError("请先选择归档建议。") }
        var operations: [ArchiveOperation] = []
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let suggestion = state.suggestions.first(where: { $0.id == id }), suggestion.status == .pending,
                  suggestion.executable, suggestion.version == state.version,
                  Date().timeIntervalSince(suggestion.createdAt) <= 86_400,
                  let rule = state.rules.first(where: { $0.directory == suggestion.directory }), rule.evidence.count >= 2 else {
                throw ArchiveError("建议已过期、分类不明确或规则已更新，请重新扫描。")
            }
            guard !state.operations.contains(where: {
                $0.suggestionID == id && $0.id != allowedOperationID && [.planned, .needsReview, .undoPlanned].contains($0.status)
            }) else {
                throw ArchiveError("此建议有关联的异常操作，请先核对操作历史。")
            }
            try ArchiveFileSystem.check(suggestion.source, role: .inbox, config: config)
            for evidence in rule.evidence {
                try ArchiveFileSystem.check(evidence.url, role: .library, config: config)
                guard try ArchiveFileSystem.fingerprint(evidence.url, maxBytes: config.maxFileBytes) == evidence.fingerprint else {
                    throw ArchiveError("分类的历史样本已变化，请重新学习资料库。")
                }
            }
            guard let target = mode.destination(for: suggestion),
                  target.lastPathComponent == (mode == .move ? suggestion.source.lastPathComponent : suggestion.proposedName),
                  try ArchiveFileSystem.normalizedName(suggestion.proposedName) == suggestion.proposedName else {
                throw ArchiveError("建议文件名无效。")
            }
            try ArchiveFileSystem.check(target, role: mode == .rename ? .inbox : .library, config: config)
            try ArchiveFileSystem.validateMove(source: suggestion.source, target: target,
                                               expected: suggestion.fingerprint, maxBytes: config.maxFileBytes)
            guard !operations.contains(where: { ArchiveFileSystem.nameKey($0.destination.path) == ArchiveFileSystem.nameKey(target.path) }) else {
                throw ArchiveError("选中的多个文件会归档到同一位置，请分开处理。")
            }
            operations.append(ArchiveOperation(suggestionID: suggestion.id, source: suggestion.source,
                                               destination: target, fingerprint: suggestion.fingerprint,
                                               staging: suggestion.source.deletingLastPathComponent().appendingPathComponent(".inchspace-archive-\(UUID().uuidString)"),
                                               undoStaging: target.deletingLastPathComponent().appendingPathComponent(".inchspace-archive-\(UUID().uuidString)")))
        }
        return operations
    }

    private func checkOperationScope(_ operation: ArchiveOperation, config: ArchiveConfiguration) throws {
        let sourceRole = operation.sourceRole ?? .inbox
        guard sourceRole != .excluded else { throw ArchiveError("无效的文件来源权限。") }
        try ArchiveFileSystem.check(operation.source, role: sourceRole, config: config)
        let role: ArchiveFolderRole = operation.destination.deletingLastPathComponent() == operation.source.deletingLastPathComponent() ? sourceRole : .library
        try ArchiveFileSystem.check(operation.destination, role: role, config: config)
    }

    func commit(_ next: ArchiveState) throws {
        try persistence.save(next)
        state = next
    }

    private func trimCache(_ next: inout ArchiveState) {
        if next.cache.count > 2_000 {
            let evidencePaths = Set(next.rules.flatMap(\.evidence).map { $0.url.path })
            next.cache = next.cache.filter { evidencePaths.contains($0.key) }
        }
    }

    func withAccess<T>(_ config: ArchiveConfiguration, body: (ArchiveConfiguration) throws -> T) throws -> T {
        var accessed: [URL] = []
        defer { for url in accessed { url.stopAccessingSecurityScopedResource() } }
        var resolved = config
        for index in resolved.folders.indices {
            let folder = resolved.folders[index]
            let url = try folder.bookmark.map(SecurityScopedBookmarkService.resolve) ?? folder.url
            guard url.standardizedFileURL == folder.url.standardizedFileURL else {
                throw ArchiveError("目录位置发生变化，请重新添加授权：\(folder.url.path)")
            }
            if url.startAccessingSecurityScopedResource() { accessed.append(url) }
            resolved.folders[index].url = url
        }
        return try body(resolved)
    }
}
