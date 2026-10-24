import Foundation

/// Every folder of the workspace with what it holds, read once for the structure audit. The counts by category
/// are local: the model only judges what a folder means and what it should be called, never how pure it is.
nonisolated struct ArchiveFolderSurvey: Sendable {
    struct Folder: Sendable {
        /// Relative to the workspace.
        var path: String
        /// The folder's own visible files, by name.
        var files: [String]
        /// The category of each of `files` that has one, by name.
        var categories: [String: String]
        /// Files anywhere inside, capped at 2,000.
        var totalFiles: Int
        /// The category the folder's name stands for in the dictionary.
        var nameCategory: String?
        var problems: [ArchiveFolderNaming.Problem]

        var name: String { (path as NSString).lastPathComponent }

        /// Direct files per category id.
        var counts: [String: Int] {
            categories.values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
    }

    var folders: [Folder]

    func folder(_ path: String) -> Folder? { folders.first { $0.path == path } }

    static func build(root: URL, folders paths: [String], records: [String: ArchiveFileRecord], convention: ArchiveConvention,
                      limit: Int = 300) -> ArchiveFolderSurvey {
        let result = paths.prefix(limit).map { path -> Folder in
            let url = root.appendingPathComponent(path, isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                                         options: [.skipsHiddenFiles])) ?? []
            var files: [String] = []
            var categories: [String: String] = [:]
            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
                let name = entry.lastPathComponent
                files.append(name)
                let topic = records[entry.path]?.topic ?? ""
                if let category = convention.category(forFile: name, size: Int64(values.fileSize ?? 0))
                    ?? (topic.isEmpty ? nil : convention.category(forTopic: topic)) {
                    categories[name] = category.id
                }
            }
            return Folder(path: path, files: files.sorted(), categories: categories, totalFiles: countFiles(url),
                          nameCategory: convention.category(forFolderName: (path as NSString).lastPathComponent)?.id,
                          problems: ArchiveFolderNaming.problems((path as NSString).lastPathComponent, convention: convention))
        }
        return ArchiveFolderSurvey(folders: result)
    }

    private static func countFiles(_ url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var count = 0
        for case let item as URL in enumerator {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            count += 1
            if count >= 2_000 { break }
        }
        return count
    }
}

/// What the audit decided about one folder.
nonisolated struct ArchiveFolderVerdict: Equatable, Sendable {
    /// Relative to the workspace.
    var path: String
    /// The dictionary category the folder holds; nil for a project or an unknown folder.
    var category: String?
    var isProject = false
    /// The name the folder should have where it is; nil when its name is fine or nothing better is known.
    /// A category folder needs none: it goes to its canonical path under the canonical name.
    var rename: String?
    /// Share of its own files that belong where they are; nil for an empty folder.
    var purity: Double?
    /// Files of a mixed folder that belong to another category, by name, with that category's id.
    var strays: [String: String] = [:]

    var isMixed: Bool { !strays.isEmpty }
}

nonisolated enum ArchiveStructureAudit {
    /// Words the model uses for "this is a project".
    private static let projectWords: Set<String> = ["项目", "project", "projects", "项目文件夹"]

    /// True when some folder is not settled by the dictionary alone, so the model has something to judge.
    static func needsModel(_ survey: ArchiveFolderSurvey) -> Bool {
        survey.folders.contains { $0.nameCategory == nil || !$0.problems.isEmpty }
    }

    /// The local survey combined with the model's answer. The model decides what a folder means and suggests names;
    /// the dictionary decides when the model said nothing; purity is always counted here.
    static func verdicts(_ survey: ArchiveFolderSurvey, answer: ArchiveAuditResponse?, convention: ArchiveConvention) -> [ArchiveFolderVerdict] {
        let answers = Dictionary((answer?.folders ?? []).map { (ArchiveFileSystem.nameKey($0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))), $0) },
                                 uniquingKeysWith: { first, _ in first })
        return survey.folders.map { folder in
            let entry = answers[ArchiveFileSystem.nameKey(folder.path)]
            var verdict = ArchiveFolderVerdict(path: folder.path)
            let said = entry?.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if projectWords.contains(said.lowercased()) {
                verdict.isProject = true
            } else if let category = convention.category(forFolderName: said) {
                verdict.category = category.id
            } else {
                // Silence, or an answer naming no category: the dictionary decides.
                verdict.category = folder.nameCategory
            }
            // The model's name for a folder whose own name breaks the convention; a name that means a category
            // makes it that category.
            if verdict.category == nil, !folder.problems.isEmpty {
                let suggested = entry?.name.flatMap { ArchiveFolderNaming.normalize($0, convention: convention) }
                if let suggested, let category = convention.category(forFolderName: suggested), !verdict.isProject {
                    verdict.category = category.id
                } else if let name = suggested ?? ArchiveFolderNaming.normalize(folder.name, convention: convention),
                          convention.category(forFolderName: name) == nil || verdict.isProject, name != folder.name {
                    verdict.rename = name
                }
            }
            if let category = verdict.category {
                if convention.topLevel == .project, isInsideProject(folder.path, convention: convention),
                   folder.name != convention.canonicalName(category) {
                    verdict.rename = convention.canonicalName(category)
                }
                let (purity, strays) = purity(of: folder, category: category, convention: convention)
                verdict.purity = purity
                verdict.strays = strays
            } else if !folder.files.isEmpty {
                verdict.purity = Double(folder.counts.values.max() ?? 0) / Double(folder.files.count)
            }
            return verdict
        }
    }

    /// The share of a category folder's own files that belong to it, and — when more than the convention's
    /// threshold belongs elsewhere — the files to move out, each with the category it belongs to. Files of no
    /// known category count against neither side.
    static func purity(of folder: ArchiveFolderSurvey.Folder, category: String,
                       convention: ArchiveConvention) -> (purity: Double?, strays: [String: String]) {
        guard !folder.files.isEmpty else { return (nil, [:]) }
        let others = folder.categories.filter { $0.value != category && $0.value != ArchiveCategory.unsorted }
        let share = Double(others.count) / Double(folder.files.count)
        // The unsorted folder holds whatever could not be placed; it is never split by type.
        guard category != ArchiveCategory.unsorted, share > convention.purityThreshold else { return (1 - share, [:]) }
        return (1 - share, others)
    }

    /// In project mode, category folders inside a project belong to that project.
    static func isInsideProject(_ path: String, convention: ArchiveConvention) -> Bool {
        guard convention.topLevel == .project, let top = path.split(separator: "/").first, path.contains("/") else { return false }
        return convention.category(forFolderName: String(top)) == nil
    }

    // MARK: Consistency check

    /// Checks what is on disk against the convention without asking the model: no category held by two folders or
    /// living away from its canonical path, no folder name breaking the rules, and every file named after its
    /// folder's pattern — the one in its record, else the one its files share.
    static func check(root: URL, folders: [String], records: [String: ArchiveFolderRecord], convention: ArchiveConvention,
                      fileLimit: Int = 200) -> ArchiveConsistencyReport {
        var report = ArchiveConsistencyReport()
        var byCategory: [String: [String]] = [:]
        let rule = convention.naming
        func absolute(_ path: String) -> String { path.isEmpty ? root.path : root.appendingPathComponent(path).path }
        for path in folders.sorted() {
            let name = (path as NSString).lastPathComponent
            let problems = ArchiveFolderNaming.problems(name, convention: convention)
            if !problems.isEmpty {
                report.issues.append(.init(kind: .folderName, path: path, detail: "「\(name)」" + problems.map(\.description).joined(separator: "、")))
            }
            let record = records[absolute(path)]
            guard record?.isProject != true,
                  let category = record?.category ?? convention.category(forFolderName: name)?.id else { continue }
            if convention.topLevel == .project, path.contains("/"),
               let top = path.split(separator: "/").first, convention.category(forFolderName: String(top)) == nil { continue }
            byCategory[category, default: []].append(path)
        }
        for (category, paths) in byCategory.sorted(by: { $0.key < $1.key }) {
            let canonical = convention.canonicalPath(category)
            let title = convention.canonicalName(category)
            if paths.count > 1 {
                for path in paths {
                    report.issues.append(.init(kind: .duplicateCategory, path: path,
                                               detail: "与 \(paths.filter { $0 != path }.joined(separator: "、")) 同为「\(title)」"))
                }
            } else if let path = paths.first, ArchiveFileSystem.nameKey(path) != ArchiveFileSystem.nameKey(canonical) {
                report.issues.append(.init(kind: .misplacedCategory, path: path, detail: "「\(title)」应位于工作区根目录的「\(canonical)」"))
            }
        }
        var fileIssues = 0
        for path in [""] + folders.sorted() {
            let url = path.isEmpty ? root : root.appendingPathComponent(path, isDirectory: true)
            let names = directFiles(url)
            guard !names.isEmpty else { continue }
            let stored = records[absolute(path)]?.pattern
            let folderPattern = stored ?? rule.derivePattern(from: names, fallback: defaultPattern(for: path, record: records[absolute(path)], convention: convention))
            for name in names {
                let pattern = path.isEmpty ? (convention.category(forFile: name)?.defaultPattern ?? .template) : folderPattern
                guard !ArchiveNameNormalizer.conforms(name, pattern: pattern, rule: rule) else { continue }
                fileIssues += 1
                let relative = path.isEmpty ? name : path + "/" + name
                if fileIssues <= fileLimit {
                    report.issues.append(.init(kind: .fileName, path: relative, detail: "「\(name)」不符合「\(pattern.label)」模式"))
                }
            }
        }
        report.omittedFileIssues = max(0, fileIssues - fileLimit)
        return report
    }

    /// The pattern a folder falls back to: its category's own, else the global template.
    static func defaultPattern(for path: String, record: ArchiveFolderRecord?, convention: ArchiveConvention) -> ArchiveNamingPattern {
        let category = record?.category ?? convention.category(forFolderName: (path as NSString).lastPathComponent)?.id
        return category.flatMap { convention.category($0)?.defaultPattern } ?? .template
    }

    static func directFiles(_ url: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map(\.lastPathComponent).sorted()
    }
}
