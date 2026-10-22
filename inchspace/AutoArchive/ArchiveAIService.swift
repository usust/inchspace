import Foundation

extension ArchiveService {
    func setDirectoryPermission(folderID: UUID, permission: ArchiveDirectoryPermission) throws {
        guard let index = state.configuration.folders.firstIndex(where: { $0.id == folderID }),
              state.configuration.folders[index].role != .excluded else { throw ArchiveError("目录不允许授权。") }
        var next = state
        next.configuration.folders[index].directoryPermission = permission
        invalidateAIAndSuggestions(&next)
        try commit(next)
        aiContext = nil
        aiPreview = nil
    }

    /// Inventory is a separate local step so users can inspect exactly what will be sent before requesting AI.
    func prepareAIContext(now: Date = Date(), includeLibraryFiles: Bool = false, limit: Int = 30, keywordLimit: Int = 80) throws -> ArchiveAIContext {
        let batchLimit = max(1, min(limit, 30))
        return try withAccess(state.configuration) { config in
            try ArchiveFileSystem.validateConfiguration(config, stateDirectory: persistence.directory)
            let (directories, directoryWarnings) = try ArchiveDirectoryFileSystem.inventory(config)
            // Metadata only: an unchanged file is recognized without reading it. Content is hashed below only
            // for the files this round actually processes.
            let inboxScan = try ArchiveFileSystem.scan(config, role: .inbox, hashing: false)
            let libraryScan = includeLibraryFiles ? try ArchiveFileSystem.scan(config, role: .library, hashing: false) : ArchiveScanResult()
            // Interleave the two sources so a large inbox cannot hide the library from a bounded plan.
            var candidates: [ArchiveEvidence] = []
            for index in 0..<max(inboxScan.files.count, libraryScan.files.count) {
                if index < inboxScan.files.count { candidates.append(inboxScan.files[index]) }
                if index < libraryScan.files.count { candidates.append(libraryScan.files[index]) }
            }
            let structure = ArchiveDirectoryFileSystem.signature(directories)
            var next = state
            var files: [ArchiveAIFile] = []
            var unsettled = 0
            var pending = 0
            var warnings = directoryWarnings + inboxScan.warnings + libraryScan.warnings
            let scanned = Set(candidates.map { $0.url.path })
            // A record whose file vanished from its path may belong to a file that was moved while the app was
            // closed (or just before a crash); the same inode, size and modification time identify it at its new path.
            var orphaned: [String: String] = [:]
            for (path, record) in next.files ?? [:] where !scanned.contains(path) {
                orphaned[record.fingerprint.identityKey] = path
            }
            for file in candidates {
                try Task.checkCancellation()
                let path = file.url.path
                if next.files?[path] == nil, let old = orphaned.removeValue(forKey: file.fingerprint.identityKey) {
                    Self.rekey(&next, from: old, to: path)
                }
                // Unchanged and settled: skipped without reading the file. Unresolved files come back once the
                // folder layout or the workspace changed, since a place may now exist for them.
                if let record = next.files?[path], record.fingerprint.sameMetadata(file.fingerprint),
                   !record.needsReview(structure: structure) { continue }
                if next.operations.contains(where: { $0.source == file.url && [.planned, .undoPlanned, .needsReview].contains($0.status) }) { continue }
                let observed = next.observations[path]
                if observed.map({ !$0.fingerprint.sameMetadata(file.fingerprint) }) ?? true {
                    next.observations[path] = ArchiveObservation(fingerprint: file.fingerprint, firstSeen: now)
                    if config.stableSeconds > 0 { unsettled += 1; continue }
                } else if let observed, now.timeIntervalSince(observed.firstSeen) < config.stableSeconds { unsettled += 1; continue }
                guard let root = config.folders.first(where: { $0.role != .excluded && ArchiveFileSystem.contains(file.url, in: $0.url) }) else { continue }
                // Avoid re-offering explicitly ignored local suggestions unless the file changed.
                if next.suggestions.contains(where: { $0.source == file.url && $0.fingerprint.sameMetadata(file.fingerprint) && $0.status == .skipped }) { continue }
                guard files.count < batchLimit else {
                    // Count the rest so the caller can show how much of the folder is still ahead.
                    pending += 1
                    continue
                }
                let fingerprint: ArchiveFingerprint
                do {
                    // An unchanged file keeps its recorded hash; anything else is hashed once here.
                    if let known = next.files?[path]?.fingerprint, known.sameMetadata(file.fingerprint), !known.sha256.isEmpty {
                        fingerprint = known
                    } else {
                        fingerprint = try ArchiveFileSystem.fingerprint(file.url)
                    }
                } catch {
                    if warnings.count < 40 { warnings.append("跳过 \(file.url.lastPathComponent)：\(error.localizedDescription)") }
                    continue
                }
                // Keyword extraction (PDF, Word, text parsing) is slow; an unchanged file reuses its last result.
                // A file that cannot be read for keywords (too large, unsupported) is still reviewed by its name.
                var words: [String] = []
                if let cached = next.cache[path], cached.fingerprint == fingerprint {
                    words = cached.words
                } else if let evidence = try? ArchiveLearning.extract(ArchiveEvidence(url: file.url, fingerprint: fingerprint, words: [], extractionNote: nil),
                                                                       maxBytes: config.maxFileBytes) {
                    words = evidence.words
                    next.cache[path] = evidence
                }
                files.append(ArchiveAIFile(id: UUID().uuidString, rootID: root.id.uuidString,
                                           relativePath: ArchiveDirectoryFileSystem.relativePath(file.url, root: root.url),
                                           source: file.url, fingerprint: fingerprint,
                                           keywords: Array(words.prefix(max(0, keywordLimit)))))
            }
            if pending > 0 { warnings.append("还有 \(pending) 个文件在之后的轮次处理。") }
            if files.isEmpty { warnings.append("没有稳定的待归档文件；新文件需至少 2 秒后重新扫描。仍可规划现有空目录清理。") }
            // Forget everything known about files that are gone from a scanned root, so the journal does not grow
            // with the folder's history. Paths outside the scanned roots (a library that was not scanned this
            // round) are kept, and a truncated scan proves nothing, so it prunes nothing.
            if !warnings.contains(where: { $0.contains("10,000") }) {
                let scannedRoots = config.inboxes + (includeLibraryFiles ? config.libraries : [])
                func isGone(_ path: String) -> Bool {
                    !scanned.contains(path) && scannedRoots.contains { path == $0.path || path.hasPrefix($0.path + "/") }
                }
                // Cached keywords are only useful until the file has been reviewed and settled.
                next.cache = next.cache.filter { !isGone($0.key) && next.files?[$0.key]?.isResolved != true }
                next.observations = next.observations.filter { !isGone($0.key) }
                next.settled = next.settled?.filter { !isGone($0.key) }
                next.files = next.files?.filter { !isGone($0.key) }
            }
            try commit(next)
            let context = ArchiveAIContext(version: state.version, createdAt: now, folders: config.folders,
                                           directories: directories, files: files, warnings: warnings,
                                           unsettledCount: unsettled, pendingCount: pending, structure: structure)
            aiContext = context
            aiPreview = nil
            return context
        }
    }

    /// Legacy bookkeeping from before per-file records; kept so older journals still load. It no longer
    /// decides which files are skipped — `files` records do.
    func markSettled(_ entries: [String: ArchiveFingerprint], removing paths: [String] = []) throws {
        var next = state
        var settled = next.settled ?? [:]
        for path in paths { settled.removeValue(forKey: path) }
        for (path, fingerprint) in entries { settled[path] = fingerprint }
        next.settled = settled
        try commit(next)
    }

    func clearSettled() throws {
        var next = state
        next.settled = nil
        next.files = nil
        try commit(next)
    }

    func previewAI(_ response: ArchiveAIResponse, contextID: UUID, records: [String: ArchiveFileRecord]? = nil) throws -> ArchiveAIPlan {
        guard let context = aiContext, context.id == contextID else { throw ArchiveError("AI 扫描快照已变化，请重新扫描。") }
        var plan = try withAccess(state.configuration) { config in
            try makeAIPlan(response, context: context, config: config)
        }
        plan.records = records
        aiPreview = plan
        return plan
    }

    func applyAI(_ planID: UUID) throws -> ArchiveAIPlan {
        guard let plan = aiPreview, plan.id == planID, let context = aiContext,
              context.id == plan.contextID else { throw ArchiveError("请先预览最新 AI 方案。") }
        return try withAccess(state.configuration) { config in
            try validateAIPlan(plan, context: context, config: config)
            guard !plan.directories.isEmpty || !plan.files.isEmpty else { throw ArchiveError("本方案没有需要执行的变更。") }
            guard !(state.ai?.plans.contains(where: { $0.id == plan.id }) ?? false) else { throw ArchiveError("方案已执行，不能重复提交。") }
            var next = state
            if next.ai == nil { next.ai = ArchiveAIState() }
            next.ai!.plans.append(plan)
            next.operations += plan.files
            try commit(next)
            aiPreview = nil
            var running = plan
            do {
                // Each mutation has a durable plan; created directories precede moves, removals follow them.
                for index in running.directories.indices where running.directories[index].action == .create {
                    let operation = running.directories[index]
                    try validateDirectoryPermission(operation, config: config)
                    try verifyAIParent(operation.target.deletingLastPathComponent(), context: context, running: running, config: config)
                    running.directories[index].resultingIdentity = try ArchiveDirectoryFileSystem.create(operation.target)
                    running.directories[index].status = .complete
                    try saveAIProgress(running)
                }
                for index in running.directories.indices where running.directories[index].action == .move {
                    let operation = running.directories[index]
                    guard let source = operation.source, let identity = operation.originalIdentity else { throw ArchiveError("移动目录缺少原始记录。") }
                    try validateDirectoryPermission(operation, config: config)
                    try verifyAIParent(source.deletingLastPathComponent(), context: context, running: running, config: config)
                    try verifyAIParent(operation.target.deletingLastPathComponent(), context: context, running: running, config: config)
                    running.directories[index].resultingIdentity = try ArchiveDirectoryFileSystem.move(source, to: operation.target, expected: identity)
                    running.directories[index].status = .complete
                    // The records for everything inside move with the folder in the same commit.
                    try saveAIProgress(running, rekey: (source.path, operation.target.path))
                }
                for index in running.files.indices {
                    let operation = running.files[index]
                    try ArchiveFileSystem.check(operation.source, role: operation.sourceRole ?? .inbox, config: config)
                    try ArchiveFileSystem.check(operation.destination, role: .library, config: config)
                    try verifyAIParent(operation.source.deletingLastPathComponent(), context: context, running: running, config: config)
                    try verifyAIParent(operation.destination.deletingLastPathComponent(), context: context, running: running, config: config)
                    try ArchiveFileSystem.move(source: operation.source, target: operation.destination, staging: operation.staging,
                                               expected: operation.fingerprint, maxBytes: config.maxFileBytes)
                    running.files[index].status = .complete
                    try saveAIProgress(running)
                }
                for index in running.directories.indices where running.directories[index].action == .removeEmpty {
                    let operation = running.directories[index]
                    try validateDirectoryPermission(operation, config: config)
                    guard let identity = operation.originalIdentity else { throw ArchiveError("删除目录缺少身份记录。") }
                    try verifyAIParent(operation.target.deletingLastPathComponent(), context: context, running: running, config: config)
                    try ArchiveDirectoryFileSystem.removeEmpty(operation.target, expected: identity)
                    running.directories[index].status = .complete
                    try saveAIProgress(running)
                }
                running.status = .complete
            } catch {
                running.status = .needsReview
                running.error = error.localizedDescription
                // Preserve uncertainty: a filesystem mutation may have succeeded before journal save failed.
                for index in running.directories.indices where running.directories[index].status == .planned {
                    running.directories[index].status = .needsReview
                    running.directories[index].error = "此项未确认完成。请检查目标目录，不会自动重放。"
                }
                for index in running.files.indices where running.files[index].status == .planned {
                    running.files[index].status = .needsReview
                    running.files[index].error = "此项未确认完成，请核对中断记录。"
                }
            }
            try saveAIProgress(running, invalidateLearning: true)
            aiContext = nil
            return running
        }
    }

    /// Undo is explicit and per directory. A created directory must be empty; a removed one is recreated without overwriting.
    func undoAIDirectory(planID: UUID, operationID: UUID) throws {
        try withAccess(state.configuration) { config in
            guard let plan = state.ai?.plans.first(where: { $0.id == planID }),
                  let index = plan.directories.firstIndex(where: { $0.id == operationID }),
                  plan.directories[index].status == .complete else { throw ArchiveError("仅可撤销已完成的目录操作。") }
            var updated = plan
            let operation = plan.directories[index]
            guard let root = config.folders.first(where: { $0.id.uuidString == operation.rootID }) else { throw ArchiveError("目录授权已移除。") }
            try ArchiveDirectoryFileSystem.checkScope(operation.target, root: root, configuration: config, deleting: operation.action != .removeEmpty)
            if operation.action == .move {
                guard root.directoryPermission?.canCreate == true, let source = operation.source,
                      let identity = operation.resultingIdentity else { throw ArchiveError("撤销移动需要“新建子目录”权限及目录身份记录。") }
                try ArchiveDirectoryFileSystem.checkScope(source, root: root, configuration: config)
                guard try ArchiveDirectoryFileSystem.identity(operation.target) == identity else { throw ArchiveError("目录身份或权限已变化，请人工核对：\(operation.target.path)") }
                guard !ArchiveFileSystem.exists(source) else { throw ArchiveError("原位置已被占用，无法移回：\(source.path)") }
            } else if operation.action == .create {
                guard root.directoryPermission?.canRemoveEmpty == true, let identity = operation.resultingIdentity else {
                    throw ArchiveError("撤销新建需要此目录的“删除空目录”权限及原始目录身份。")
                }
                try ArchiveDirectoryFileSystem.validateRemoval(operation.target, expected: identity)
            } else {
                guard root.directoryPermission?.canCreate == true else { throw ArchiveError("撤销删除需要此目录的“新建子目录”权限。") }
                try ArchiveDirectoryFileSystem.validateCreate(operation.target)
            }
            updated.directories[index].status = .undoPlanned
            try saveAIProgress(updated, synchronizeFiles: false)
            var rekey: (String, String)?
            do {
                if operation.action == .move, let source = operation.source {
                    _ = try ArchiveDirectoryFileSystem.move(operation.target, to: source, expected: operation.resultingIdentity!)
                    rekey = (operation.target.path, source.path)
                } else if operation.action == .create {
                    try ArchiveDirectoryFileSystem.removeEmpty(operation.target, expected: operation.resultingIdentity!)
                } else {
                    _ = try ArchiveDirectoryFileSystem.create(operation.target, permissions: operation.originalIdentity?.permissions ?? 0o755)
                }
                updated.directories[index].status = .undone
                updated.directories[index].error = nil
            } catch {
                updated.directories[index].status = .needsReview
                updated.directories[index].error = error.localizedDescription
                try saveAIProgress(updated, invalidateLearning: true, synchronizeFiles: false)
                throw error
            }
            try saveAIProgress(updated, invalidateLearning: true, synchronizeFiles: false, rekey: rekey)
        }
    }

    func recoverAIDirectories() throws {
        var next = state
        guard var ai = next.ai else { return }
        var changed = false
        for p in ai.plans.indices {
            for d in ai.plans[p].directories.indices where [.planned, .undoPlanned].contains(ai.plans[p].directories[d].status) {
                ai.plans[p].directories[d].status = .needsReview
                ai.plans[p].directories[d].error = "上次目录操作被中断，无法确定创建或删除是否已提交。请检查目标路径；不会自动重放或删除。"
                changed = true
            }
            if ai.plans[p].status == .planned {
                ai.plans[p].status = .needsReview
                ai.plans[p].error = "方案执行被中断，请查看各项结果和文件操作记录。"
                changed = true
            }
        }
        if changed { next.ai = ai; invalidateAIAndSuggestions(&next); try commit(next) }
    }

    private func makeAIPlan(_ response: ArchiveAIResponse, context: ArchiveAIContext, config: ArchiveConfiguration) throws -> ArchiveAIPlan {
        guard response.directories.count <= 20, response.files.count <= 30,
              !response.summary.isEmpty, response.summary.count <= 4_000 else { throw ArchiveError("AI 方案超出限制。") }
        var directories: [ArchiveDirectoryOperation] = []
        for request in response.directories {
            let (_, target) = try ArchiveDirectoryFileSystem.target(rootID: request.rootID, relativePath: request.relativePath, configuration: config)
            guard !directories.contains(where: { ArchiveFileSystem.nameKey($0.target.path) == ArchiveFileSystem.nameKey(target.path) }),
                  !request.reason.isEmpty, request.reason.count <= 1_000 else { throw ArchiveError("AI 方案包含重复目录或无效说明。") }
            let existing = context.directories.first { $0.rootID == request.rootID && $0.relativePath == request.relativePath }
            var source: URL?
            var identity = existing?.identity
            switch request.action {
            case .removeEmpty:
                guard let existing, existing.isEmpty else { throw ArchiveError("AI 只能删除扫描时已经为空的目录。") }
            case .create:
                guard existing == nil else { throw ArchiveError("AI 试图新建已有目录。") }
            case .move:
                guard existing == nil, let sourcePath = request.source,
                      let original = context.directories.first(where: { $0.rootID == request.rootID && $0.relativePath == sourcePath }) else {
                    throw ArchiveError("只能移动扫描快照中的目录，且目标不能已存在。")
                }
                let (_, from) = try ArchiveDirectoryFileSystem.target(rootID: request.rootID, relativePath: sourcePath, configuration: config)
                guard !ArchiveFileSystem.contains(target, in: from),
                      !directories.contains(where: { other in
                          other.source.map { ArchiveFileSystem.contains(from, in: $0) || ArchiveFileSystem.contains($0, in: from) } ?? false
                      }) else { throw ArchiveError("同一方案中的目录移动互相嵌套。") }
                // The whole subtree moves, so its deepest folder must still fit under the depth limit.
                let depth = { (path: String) in path.split(separator: "/").count }
                let subtree = context.directories.filter { $0.rootID == request.rootID && $0.relativePath.hasPrefix(sourcePath + "/") }
                    .map { depth($0.relativePath) - depth(sourcePath) }.max() ?? 0
                guard depth(request.relativePath) + subtree <= 6 else { throw ArchiveError("移动后目录层级超过六层。") }
                source = from
                identity = original.identity
            }
            directories.append(ArchiveDirectoryOperation(action: request.action, rootID: request.rootID, target: target,
                                                         reason: request.reason, originalIdentity: identity, source: source))
        }
        directories.sort {
            if $0.action != $1.action { return $0.action.order < $1.action.order }
            return $0.target.pathComponents.count < $1.target.pathComponents.count
        }
        guard response.files.isEmpty || !directories.contains(where: { $0.action == .move }) else {
            throw ArchiveError("目录移动与文件移动需分开规划。")
        }
        var files: [ArchiveOperation] = []
        for request in response.files {
            guard let file = context.files.first(where: { $0.id == request.fileID }),
                  !files.contains(where: { $0.source == file.source }),
                  !request.reason.isEmpty, request.reason.count <= 1_000 else { throw ArchiveError("AI 引用了未知或重复文件。") }
            let (root, directory) = try ArchiveDirectoryFileSystem.target(rootID: request.rootID, relativePath: request.relativeDirectory,
                                                                          configuration: config, allowsRoot: true)
            guard config.libraries.contains(root.url) else { throw ArchiveError("AI 文件只能归档到资料库。") }
            let name = try ArchiveAINamePolicy.validate(request.proposedName, original: file.source)
            let destination = directory.appendingPathComponent(name)
            guard destination.path != file.source.path else { throw ArchiveError("AI 方案包含位置和名称都未变化的文件，请省略该项。") }
            guard let sourceFolder = config.folders.first(where: { $0.id.uuidString == file.rootID && $0.role != .excluded }),
                  ArchiveFileSystem.contains(file.source, in: sourceFolder.url) else { throw ArchiveError("文件来源授权已变化。") }
            guard !files.contains(where: { ArchiveFileSystem.nameKey($0.destination.path) == ArchiveFileSystem.nameKey(destination.path) }) else {
                throw ArchiveError("AI 文件目标互相冲突。")
            }
            files.append(ArchiveOperation(suggestionID: UUID(), source: file.source, destination: destination,
                                          fingerprint: file.fingerprint,
                                          staging: file.source.deletingLastPathComponent().appendingPathComponent(".inchspace-archive-\(UUID().uuidString)"),
                                          undoStaging: directory.appendingPathComponent(".inchspace-archive-\(UUID().uuidString)"),
                                          reason: request.reason, sourceRole: sourceFolder.role))
        }
        let plan = ArchiveAIPlan(contextID: context.id, version: context.version, summary: response.summary, directories: directories, files: files)
        try validateAIPlan(plan, context: context, config: config)
        return plan
    }

    private func validateAIPlan(_ plan: ArchiveAIPlan, context: ArchiveAIContext, config: ArchiveConfiguration) throws {
        guard plan.version == state.version, context.version == state.version,
              Date().timeIntervalSince(context.createdAt) <= 3_600 else { throw ArchiveError("AI 方案已过期或权限、目录规则已变化，请重新扫描和规划。") }
        try ArchiveFileSystem.validateConfiguration(config, stateDirectory: persistence.directory)
        let unresolved = (state.ai?.plans ?? []).flatMap(\.directories).filter {
            [.planned, .undoPlanned, .needsReview].contains($0.status)
        }
        let affected = plan.directories.map(\.target) + plan.directories.compactMap(\.source) + plan.files.flatMap { [$0.source, $0.destination] }
        guard !unresolved.contains(where: { previous in
            affected.contains { ArchiveFileSystem.contains($0, in: previous.target) || ArchiveFileSystem.contains(previous.target, in: $0) }
        }) else { throw ArchiveError("此目录存在未确认的历史操作，请先人工核对并使用其他分类位置。") }
        let creates = plan.directories.filter { $0.action == .create }
        let removals = plan.directories.filter { $0.action == .removeEmpty }
        let moves = plan.directories.filter { $0.action == .move }
        for operation in plan.directories {
            try validateDirectoryPermission(operation, config: config)
            if operation.action == .move {
                guard let source = operation.source, let identity = operation.originalIdentity,
                      try ArchiveDirectoryFileSystem.identity(source) == identity else { throw ArchiveError("待移动目录已变化，请重新规划。") }
                guard !ArchiveFileSystem.exists(operation.target) else { throw ArchiveError("目录移动目标已被占用。") }
                try verifyAIParent(source.deletingLastPathComponent(), context: context, running: nil, config: config)
                let parent = operation.target.deletingLastPathComponent()
                if !creates.contains(where: { $0.target == parent }) {
                    try verifyAIParent(parent, context: context, running: nil, config: config)
                    try ArchiveFileSystem.checkCollision(operation.target, ignoring: source)
                }
                guard !removals.contains(where: { ArchiveFileSystem.contains(source, in: $0.target) || ArchiveFileSystem.contains(parent, in: $0.target) }) else {
                    throw ArchiveError("不能删除本方案仍在使用的目录。")
                }
            } else if operation.action == .create {
                guard plan.files.contains(where: { ArchiveFileSystem.contains($0.destination, in: operation.target) })
                        || moves.contains(where: { ArchiveFileSystem.contains($0.target, in: operation.target) }) else {
                    throw ArchiveError("新建分类目录必须承接本次归档的文件或目录。")
                }
                guard !ArchiveFileSystem.exists(operation.target) else { throw ArchiveError("新建目标已被占用。") }
                let parent = operation.target.deletingLastPathComponent()
                if !creates.contains(where: { $0.target == parent }) {
                    try verifyAIParent(parent, context: context, running: nil, config: config)
                    try ArchiveDirectoryFileSystem.validateCreate(operation.target)
                }
            } else {
                guard let identity = operation.originalIdentity else { throw ArchiveError("删除目录缺少身份记录。") }
                try ArchiveDirectoryFileSystem.validateRemoval(operation.target, expected: identity)
                try verifyAIParent(operation.target.deletingLastPathComponent(), context: context, running: nil, config: config)
                guard !creates.contains(where: { ArchiveFileSystem.contains($0.target, in: operation.target) }),
                      !plan.files.contains(where: { ArchiveFileSystem.contains($0.destination, in: operation.target) || ArchiveFileSystem.contains($0.source, in: operation.target) }) else {
                    throw ArchiveError("不能删除本方案仍在使用的目录。")
                }
            }
        }
        for operation in plan.files {
            try ArchiveFileSystem.check(operation.source, role: operation.sourceRole ?? .inbox, config: config)
            try verifyAIParent(operation.source.deletingLastPathComponent(), context: context, running: nil, config: config)
            guard try ArchiveFileSystem.fingerprint(operation.source, maxBytes: config.maxFileBytes) == operation.fingerprint else {
                throw ArchiveError("待归档文件已变化，请重新规划。")
            }
            guard !state.operations.contains(where: { $0.source == operation.source && [.planned, .undoPlanned, .needsReview].contains($0.status) }) else {
                throw ArchiveError("文件有未核对的历史操作，请先恢复检查。")
            }
            let parent = operation.destination.deletingLastPathComponent()
            if creates.contains(where: { $0.target == parent }) {
                var ancestor = parent
                while creates.contains(where: { $0.target == ancestor }) { ancestor.deleteLastPathComponent() }
                try verifyAIParent(ancestor, context: context, running: nil, config: config)
                guard try ArchiveDirectoryFileSystem.identity(ancestor).device == operation.fingerprint.device else {
                    throw ArchiveError("暂不支持跨磁盘归档。")
                }
            } else {
                try verifyAIParent(parent, context: context, running: nil, config: config)
                try ArchiveFileSystem.check(operation.destination, role: .library, config: config)
                try ArchiveFileSystem.validateMove(source: operation.source, target: operation.destination,
                                                   expected: operation.fingerprint, maxBytes: config.maxFileBytes)
            }
            guard !removals.contains(where: { ArchiveFileSystem.contains(parent, in: $0.target) }) else { throw ArchiveError("目标目录将被删除。") }
        }
    }

    private func validateDirectoryPermission(_ operation: ArchiveDirectoryOperation, config: ArchiveConfiguration) throws {
        guard let root = config.folders.first(where: { $0.id.uuidString == operation.rootID }), root.role != .excluded else {
            throw ArchiveError("目录授权已移除。")
        }
        let permitted = operation.action == .removeEmpty ? root.directoryPermission?.canRemoveEmpty : root.directoryPermission?.canCreate
        guard permitted == true else { throw ArchiveError("没有“\(operation.action.title)”权限：\(root.url.path)") }
        try ArchiveDirectoryFileSystem.checkScope(operation.target, root: root, configuration: config, deleting: operation.action == .removeEmpty)
        // Moving a folder away is as strong as removing it: never a root, an exclusion or anything containing one.
        if let source = operation.source { try ArchiveDirectoryFileSystem.checkScope(source, root: root, configuration: config, deleting: true) }
    }

    private func verifyAIParent(_ url: URL, context: ArchiveAIContext, running: ArchiveAIPlan?, config: ArchiveConfiguration) throws {
        if let created = running?.directories.first(where: { $0.target == url && $0.action == .create && $0.status == .complete }),
           let expected = created.resultingIdentity {
            guard try ArchiveDirectoryFileSystem.identity(url) == expected else { throw ArchiveError("新建目录被替换。") }
            return
        }
        guard let entry = context.directories.first(where: { entry in
            guard let root = config.folders.first(where: { $0.id.uuidString == entry.rootID }) else { return false }
            let target = entry.relativePath.isEmpty ? root.url : root.url.appendingPathComponent(entry.relativePath, isDirectory: true)
            return target == url
        }), try ArchiveDirectoryFileSystem.identity(url) == entry.identity else {
            throw ArchiveError("目标或源目录不在扫描快照中，或身份已变化：\(url.path)")
        }
    }

    private func saveAIProgress(_ plan: ArchiveAIPlan, invalidateLearning: Bool = false, synchronizeFiles: Bool = true,
                                rekey: (String, String)? = nil) throws {
        var next = state
        guard let index = next.ai?.plans.firstIndex(where: { $0.id == plan.id }) else { throw ArchiveError("AI 操作记录不存在。") }
        next.ai!.plans[index] = plan
        if synchronizeFiles {
            for operation in plan.files {
                if let fileIndex = next.operations.firstIndex(where: { $0.id == operation.id }) { next.operations[fileIndex] = operation }
                // A file's result is saved in the same commit that confirms its move, so the two never disagree.
                if operation.status == .complete, var record = plan.records?[operation.source.path] {
                    record.path = operation.destination.path
                    var files = next.files ?? [:]
                    files.removeValue(forKey: operation.source.path)
                    files[record.path] = record
                    next.files = files
                }
            }
        }
        if let (from, to) = rekey { Self.rekey(&next, from: from, to: to) }
        if invalidateLearning { invalidateAIAndSuggestions(&next); next.rules = []; next.report = nil; next.cache = [:] }
        try commit(next)
    }

    private func invalidateAIAndSuggestions(_ next: inout ArchiveState) {
        next.version += 1
        for index in next.suggestions.indices where next.suggestions[index].status == .pending { next.suggestions[index].status = .stale }
    }
}
