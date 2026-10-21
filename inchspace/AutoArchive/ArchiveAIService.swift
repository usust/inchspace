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
    func prepareAIContext(now: Date = Date(), includeLibraryFiles: Bool = false) throws -> ArchiveAIContext {
        try withAccess(state.configuration) { config in
            try ArchiveFileSystem.validateConfiguration(config, stateDirectory: persistence.directory)
            let (directories, directoryWarnings) = try ArchiveDirectoryFileSystem.inventory(config)
            let inboxScan = try ArchiveFileSystem.scan(config, role: .inbox)
            let libraryScan = includeLibraryFiles ? try ArchiveFileSystem.scan(config, role: .library) : ArchiveScanResult()
            // Interleave the two sources so a large inbox cannot hide the library from a bounded plan.
            var candidates: [ArchiveEvidence] = []
            for index in 0..<max(inboxScan.files.count, libraryScan.files.count) {
                if index < inboxScan.files.count { candidates.append(inboxScan.files[index]) }
                if index < libraryScan.files.count { candidates.append(libraryScan.files[index]) }
            }
            var next = state
            var files: [ArchiveAIFile] = []
            var unsettled = 0
            var warnings = directoryWarnings + inboxScan.warnings + libraryScan.warnings
            if candidates.count > 30 { warnings.append("扫描范围包含 \(candidates.count) 个可读文件，本轮最多提供 30 个；方案仅针对本轮文件，不代表全库最优。") }
            for file in candidates {
                try Task.checkCancellation()
                if next.operations.contains(where: { $0.source == file.url && [.planned, .undoPlanned, .needsReview].contains($0.status) }) { continue }
                let observed = next.observations[file.url.path]
                if next.settled?[file.url.path] == file.fingerprint { continue }
                if observed?.fingerprint != file.fingerprint {
                    next.observations[file.url.path] = ArchiveObservation(fingerprint: file.fingerprint, firstSeen: now)
                    if config.stableSeconds > 0 { unsettled += 1; continue }
                } else if let observed, now.timeIntervalSince(observed.firstSeen) < config.stableSeconds { unsettled += 1; continue }
                guard files.count < 30 else { warnings.append("最多提供 30 个稳定文件，请完成本轮后重新扫描。"); break }
                guard let root = config.folders.first(where: { $0.role != .excluded && ArchiveFileSystem.contains(file.url, in: $0.url) }) else { continue }
                // Avoid re-offering explicitly ignored local suggestions unless the file changed.
                if next.suggestions.contains(where: { $0.source == file.url && $0.fingerprint == file.fingerprint && $0.status == .skipped }) { continue }
                do {
                    let evidence = try ArchiveLearning.extract(file, maxBytes: config.maxFileBytes)
                    files.append(ArchiveAIFile(id: UUID().uuidString, rootID: root.id.uuidString,
                                               relativePath: ArchiveDirectoryFileSystem.relativePath(file.url, root: root.url),
                                               source: file.url, fingerprint: file.fingerprint,
                                               keywords: Array(evidence.words.prefix(80))))
                    if let note = evidence.extractionNote { warnings.append("\(file.url.lastPathComponent)：\(note)") }
                } catch { warnings.append("跳过 \(file.url.lastPathComponent)：\(error.localizedDescription)") }
            }
            if files.isEmpty { warnings.append("没有稳定的待归档文件；新文件需至少 2 秒后重新扫描。仍可规划现有空目录清理。") }
            try commit(next)
            let context = ArchiveAIContext(version: state.version, createdAt: now, folders: config.folders,
                                           directories: directories, files: files, warnings: warnings,
                                           unsettledCount: unsettled)
            aiContext = context
            aiPreview = nil
            return context
        }
    }

    /// Records reviewed files so unchanged ones are not offered to the model again.
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
        try commit(next)
    }

    func previewAI(_ response: ArchiveAIResponse, contextID: UUID) throws -> ArchiveAIPlan {
        guard let context = aiContext, context.id == contextID else { throw ArchiveError("AI 扫描快照已变化，请重新扫描。") }
        let plan = try withAccess(state.configuration) { config in
            try makeAIPlan(response, context: context, config: config)
        }
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
            try ArchiveDirectoryFileSystem.checkScope(operation.target, root: root, configuration: config, deleting: operation.action == .create)
            if operation.action == .create {
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
            do {
                if operation.action == .create {
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
            try saveAIProgress(updated, invalidateLearning: true, synchronizeFiles: false)
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
            if request.action == .removeEmpty {
                guard let existing, existing.isEmpty else { throw ArchiveError("AI 只能删除扫描时已经为空的目录。") }
            } else if existing != nil { throw ArchiveError("AI 试图新建已有目录。") }
            directories.append(ArchiveDirectoryOperation(action: request.action, rootID: request.rootID, target: target,
                                                         reason: request.reason, originalIdentity: existing?.identity))
        }
        directories.sort {
            if $0.action != $1.action { return $0.action == .create }
            return $0.target.pathComponents.count < $1.target.pathComponents.count
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
        let affected = plan.directories.map(\.target) + plan.files.flatMap { [$0.source, $0.destination] }
        guard !unresolved.contains(where: { previous in
            affected.contains { ArchiveFileSystem.contains($0, in: previous.target) || ArchiveFileSystem.contains(previous.target, in: $0) }
        }) else { throw ArchiveError("此目录存在未确认的历史操作，请先人工核对并使用其他分类位置。") }
        let creates = plan.directories.filter { $0.action == .create }
        let removals = plan.directories.filter { $0.action == .removeEmpty }
        for operation in plan.directories {
            try validateDirectoryPermission(operation, config: config)
            if operation.action == .create {
                guard plan.files.contains(where: { ArchiveFileSystem.contains($0.destination, in: operation.target) }) else {
                    throw ArchiveError("新建分类目录必须承接本次归档文件。")
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
        let permitted = operation.action == .create ? root.directoryPermission?.canCreate : root.directoryPermission?.canRemoveEmpty
        guard permitted == true else { throw ArchiveError("没有“\(operation.action.title)”权限：\(root.url.path)") }
        try ArchiveDirectoryFileSystem.checkScope(operation.target, root: root, configuration: config, deleting: operation.action == .removeEmpty)
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

    private func saveAIProgress(_ plan: ArchiveAIPlan, invalidateLearning: Bool = false, synchronizeFiles: Bool = true) throws {
        var next = state
        guard let index = next.ai?.plans.firstIndex(where: { $0.id == plan.id }) else { throw ArchiveError("AI 操作记录不存在。") }
        next.ai!.plans[index] = plan
        if synchronizeFiles {
            for operation in plan.files {
                if let fileIndex = next.operations.firstIndex(where: { $0.id == operation.id }) { next.operations[fileIndex] = operation }
            }
        }
        if invalidateLearning { invalidateAIAndSuggestions(&next); next.rules = []; next.report = nil; next.cache = [:] }
        try commit(next)
    }

    private func invalidateAIAndSuggestions(_ next: inout ArchiveState) {
        next.version += 1
        for index in next.suggestions.indices where next.suggestions[index].status == .pending { next.suggestions[index].status = .stale }
    }
}
