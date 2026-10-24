import Foundation

/// One kind of content with exactly one home in the workspace (`ArchiveConvention.canonicalPath`).
nonisolated struct ArchiveCategory: Codable, Equatable, Identifiable, Sendable {
    /// Stable key, independent of the language names are shown in.
    var id: String
    var chinese: String
    var english: String
    /// Other names that mean the same thing, in any language; compared by `ArchiveFileSystem.nameKey`.
    var synonyms: [String]
    /// Lowercased extensions whose files belong here.
    var extensions: Set<String>
    /// Words in a file name that place it here whatever its extension (`github-token.txt` is a credential).
    var nameHints: [String] = []
    /// How files in this category's folder are named when its own files show no common structure.
    var defaultPattern: ArchiveNamingPattern = .template

    func name(in language: ArchiveConvention.Language) -> String { language == .chinese ? chinese : english }

    static let music = "music", video = "video", image = "image", document = "document", installer = "installer",
               credential = "credential", code = "code", archive = "archive", large = "large", unsorted = "unsorted"

    static let builtIn: [ArchiveCategory] = [
        ArchiveCategory(id: music, chinese: "音乐", english: "Music",
                        synonyms: ["音频", "歌曲", "单曲", "Audio", "Songs", "Song", "iTunes", "Musics"],
                        extensions: ["mp3", "flac", "ape", "wav", "aac", "m4a", "aiff", "aif", "ogg", "opus", "wma", "alac", "dsf", "dff", "mid", "midi"],
                        defaultPattern: .artistTitle),
        ArchiveCategory(id: video, chinese: "视频", english: "Videos",
                        synonyms: ["影片", "电影", "Video", "Movies", "Movie", "Films"],
                        extensions: ["mp4", "mov", "mkv", "avi", "m4v", "webm", "wmv", "flv", "rmvb", "rm", "ts", "m2ts", "mts", "3gp", "vob", "mpg", "mpeg"]),
        ArchiveCategory(id: image, chinese: "图片", english: "Images",
                        synonyms: ["照片", "相片", "截图", "截屏", "图像", "Photos", "Photo", "Pictures", "Picture", "Image", "Screenshots", "Pics"],
                        extensions: ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "svg", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "ico"]),
        ArchiveCategory(id: document, chinese: "文档", english: "Documents",
                        synonyms: ["文件", "资料", "文稿", "Docs", "Doc", "Document", "Papers"],
                        extensions: ["pdf", "doc", "docx", "txt", "md", "rtf", "pages", "xls", "xlsx", "csv", "tsv", "numbers", "ppt", "pptx",
                                     "keynote", "epub", "odt", "ods", "odp", "wps"]),
        ArchiveCategory(id: installer, chinese: "安装包与镜像", english: "Installers",
                        synonyms: ["安装包", "镜像", "软件", "Software", "Apps", "ISO", "Disk Images", "Installer", "Setup"],
                        extensions: ["dmg", "pkg", "mpkg", "iso", "img", "exe", "msi", "apk", "ipa", "xapk", "deb", "rpm", "appimage",
                                     "vmdk", "vdi", "qcow2", "ova"]),
        ArchiveCategory(id: credential, chinese: "密钥与凭据", english: "Credentials",
                        // Not 证书/Certificates: such a folder as often holds diploma scans as TLS certificates.
                        synonyms: ["密钥", "凭据", "凭证", "密码", "令牌", "Keys", "Key", "Secrets", "Secret", "Tokens", "Token",
                                   "Passwords", "Credential"],
                        extensions: ["pem", "key", "p12", "pfx", "cer", "crt", "der", "csr", "kdbx", "kdb", "keychain", "ovpn", "gpg", "asc",
                                     "jks", "keystore", "ppk", "mobileprovision", "p8"],
                        nameHints: ["token", "secret", "password", "passwd", "apikey", "api-key", "api_key", "credential", "id-rsa", "id_rsa",
                                    "id-ed25519", "id_ed25519", "密钥", "密码", "凭据", "令牌"]),
        ArchiveCategory(id: code, chinese: "代码", english: "Code",
                        synonyms: ["源码", "源代码", "脚本", "Source", "Scripts", "Src", "Projects Code"],
                        extensions: ["swift", "py", "js", "mjs", "ts", "tsx", "jsx", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "go", "rs",
                                     "rb", "php", "sh", "zsh", "bash", "ps1", "lua", "sql", "ipynb", "html", "css", "scss", "vue", "yaml", "yml", "toml"]),
        ArchiveCategory(id: archive, chinese: "压缩包", english: "Archives",
                        synonyms: ["压缩文件", "归档文件", "Archive", "Zips", "Compressed"],
                        extensions: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz", "cab"]),
        ArchiveCategory(id: large, chinese: "大文件", english: "Large Files", synonyms: ["Large"], extensions: []),
        ArchiveCategory(id: unsorted, chinese: "待分类", english: "Unsorted",
                        synonyms: ["未分类", "待整理", "Inbox", "To Sort"], extensions: []),
    ]
}

/// The directory convention: the one source of truth every stage reads and every prompt quotes.
/// - Top-level folders are categories or projects, never both dimensions mixed on one level.
/// - Each category has exactly one home in the workspace, its canonical path.
/// - Folder names are single, meaningful, non-placeholder names (`ArchiveFolderNaming`).
/// - Usually one to three levels; never deeper than `maxDepth`.
nonisolated struct ArchiveConvention: Codable, Equatable, Sendable {
    enum Language: String, Codable, Sendable { case chinese, english }
    /// What separates the words inside one field of a file name; one choice for the whole workspace.
    enum WordSeparator: String, Codable, Sendable {
        case hyphen = "-", space = " "
    }
    /// What the top level is organized by.
    enum TopLevel: String, Codable, Sendable {
        /// Categories own the top level; a category folder found anywhere is merged into its canonical path.
        case category
        /// Projects own the top level; category folders inside a project belong to that project and stay.
        case project
    }

    var language: Language = .chinese
    var wordSeparator: WordSeparator = .hyphen
    var topLevel: TopLevel = .category
    /// A folder is mixed when more than this share of its files belongs to another category.
    var purityThreshold = 0.3
    var maxDepth = 4
    var categories = ArchiveCategory.builtIn
    /// Category names chosen by the user, keyed by category id; they replace the built-in name in both languages.
    var customNames: [String: String] = [:]

    static let standard = ArchiveConvention()

    var naming: ArchiveNamingRule { ArchiveNamingRule(wordSeparator: wordSeparator) }

    func category(_ id: String) -> ArchiveCategory? { categories.first { $0.id == id } }

    func canonicalName(_ id: String) -> String {
        if let custom = customNames[id] { return custom }
        return category(id)?.name(in: language) ?? id
    }

    /// The one place a category lives: a folder with its canonical name in the workspace itself.
    func canonicalPath(_ id: String) -> String { canonicalName(id) }

    /// Every name that means this category: its names in both languages, the user's name and the synonyms.
    func names(of category: ArchiveCategory) -> [String] {
        [category.chinese, category.english, category.id] + category.synonyms + (customNames[category.id].map { [$0] } ?? [])
    }

    /// The category a folder name stands for, by the dictionary alone.
    func category(forFolderName name: String) -> ArchiveCategory? {
        let key = ArchiveFileSystem.nameKey(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty else { return nil }
        return categories.first { category in names(of: category).contains { ArchiveFileSystem.nameKey($0) == key } }
    }

    /// The category a file belongs to by its name and extension; nil when neither says.
    func category(forFile name: String, size: Int64 = 0) -> ArchiveCategory? {
        let lower = name.lowercased()
        if let hinted = categories.first(where: { category in category.nameHints.contains { lower.contains($0) } }) { return hinted }
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let byExtension = categories.first(where: { $0.extensions.contains(ext) }) { return byExtension }
        return size >= ArchiveFileKind.largeFileBytes ? category(ArchiveCategory.large) : nil
    }

    /// A topic found by an earlier review, read as a category when it is one of the dictionary's names.
    func category(forTopic topic: String) -> ArchiveCategory? {
        category(forFolderName: topic)
    }

    /// The same text is quoted in every stage's instructions, so the stages never disagree about the rules.
    var ruleText: String {
        let dictionary = categories.map { category in
            "\(canonicalName(category.id))（同义：\(([category.chinese, category.english] + category.synonyms).filter { $0 != canonicalName(category.id) }.prefix(6).joined(separator: "、"))）"
        }.joined(separator: "；")
        let top = topLevel == .category
            ? "顶层按类别组织：每个类别只有一个归宿，就是工作区根目录下用规范名命名的文件夹；项目文件夹也可以在顶层，但同一层不要混用按类别和按项目两种维度的子文件夹。"
            : "顶层按项目组织：项目文件夹在顶层，项目内部可以有自己的类别子文件夹；项目以外的同类文件仍只有一个归宿。"
        return """
        【目录规范】
        1. \(top)
        2. 类别词典（规范名与同义名）：\(dictionary)。凡含义属于词典中的类别，一律使用规范名，不得另起同义名。
        3. 文件夹名是单层名称：不含 / : \\，不以 . 或 ~ 开头；不要无语义前缀（如 A__、01_）或占位名（新建文件夹、temp、其他、杂项、未命名、纯日期或纯数字）；同一父目录下不能有含义重复的名字（如“照片”和“图片”）。
        4. 层级通常一到三层，最多 \(maxDepth) 层；同一层的分类维度一致（都按类别、都按项目或都按时间）。
        5. 名称语言统一使用\(language == .chinese ? "中文" : "英文")。
        \(naming.ruleText)
        """
    }
}

// MARK: - Naming

/// How the file names inside one folder are built. Every file of a folder follows the same pattern.
nonisolated struct ArchiveNamingPattern: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// `主题[_类型][_日期][_编号][_版本].ext`: fields in fixed order, joined by `_`.
        case template
        /// `歌手 - 歌名.ext`: two parts joined by ` - `.
        case artistTitle
    }

    var kind: Kind
    /// The fields the folder's files usually carry, as shown to the model (`主题_日期_编号`).
    var label: String

    static let template = ArchiveNamingPattern(kind: .template, label: "主题_类型_日期_编号_版本")
    static let artistTitle = ArchiveNamingPattern(kind: .artistTitle, label: "歌手 - 歌名")
}

/// The file name convention, enforced locally by `ArchiveNameNormalizer`.
nonisolated struct ArchiveNamingRule: Codable, Equatable, Sendable {
    /// Separates fields of the template.
    static let fieldSeparator = "_"
    var wordSeparator: ArchiveConvention.WordSeparator = .hyphen

    var ruleText: String {
        """
        【命名规范】
        1. 文件名模板：主题[_类型][_日期][_编号][_版本].原扩展名。字段按证据取舍，顺序固定，字段之间用 _，字段内部的多个词用“\(wordSeparator == .hyphen ? "-" : "空格")”连接。
        2. 日期统一写成 YYYY-MM-DD，只在原名已有日期时保留并规范写法，不得凭修改时间编造。
        3. 必须保留原扩展名及大小写，以及原名中的日期、编号和版本标识。
        4. 去掉噪声：(1)、(2)、- 副本、copy、final、最终版2、多余空白、连续分隔符、首尾标点、全角括号。
        5. 每个文件夹有自己的命名模式（如音乐用“歌手 - 歌名”），同一文件夹内的文件必须用同一个模式；给出名称时按目标文件夹的模式写。
        """
    }

    /// The pattern a folder's existing files share; the category's default when they share none.
    func derivePattern(from names: [String], fallback: ArchiveNamingPattern = .template) -> ArchiveNamingPattern {
        // Songs keep `歌手 - 歌名`; a single-part name such as `track01` fits that pattern too.
        if fallback.kind == .artistTitle { return fallback }
        let stems = names.map { ($0 as NSString).deletingPathExtension }.filter { !$0.isEmpty }
        guard stems.count >= 2 else { return fallback }
        let artistTitle = stems.filter { stem in
            let parts = stem.components(separatedBy: " - ")
            return parts.count == 2 && parts.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }.count
        if Double(artistTitle) >= Double(stems.count) * 0.6 { return .artistTitle }
        // The template's fields the names carry most of the time, in template order.
        var counts: [ArchiveNameNormalizer.Field: Int] = [:]
        for stem in stems {
            for field in Set(ArchiveNameNormalizer.fields(of: stem, rule: self)) { counts[field, default: 0] += 1 }
        }
        let common = ArchiveNameNormalizer.Field.allCases.filter { field in
            field == .subject || Double(counts[field] ?? 0) >= Double(stems.count) * 0.5
        }
        return ArchiveNamingPattern(kind: .template, label: common.map(\.title).joined(separator: "_"))
    }
}

// MARK: - Preference

extension ArchiveConvention {
    /// The default preference text shown to the user; parsing it yields the standard convention.
    static let defaultPreference = "按类别整理，类别名用中文；文件名中多个词用 - 连接。"

    /// Reads the user's preference, written in plain words, as overrides of the convention. Only the choices the
    /// convention offers are taken from it (language, word separator, projects first, mixed-folder threshold, a
    /// category's own name); everything else in the text is ignored, so a preference can never widen what runs do.
    static func parse(preference: String, base: ArchiveConvention = .standard) -> ArchiveConvention {
        var convention = base
        let text = preference.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if has(["英文", "english", "英语"]) { convention.language = .english }
        if has(["中文", "chinese", "汉字"]) && !has(["英文", "english", "英语"]) { convention.language = .chinese }
        if has(["空格连接", "用空格", "空格分隔", "space"]) { convention.wordSeparator = .space }
        if has(["- 连接", "-连接", "连字符", "短横", "hyphen"]) { convention.wordSeparator = .hyphen }
        if has(["按项目", "项目优先", "project"]) { convention.topLevel = .project }
        if has(["按类别", "类别优先", "按类型", "category"]) && !has(["按项目", "项目优先", "project"]) { convention.topLevel = .category }
        if let match = text.range(of: "(?:阈值|混合)[^0-9]{0,6}([0-9]{1,2})\\s*%", options: .regularExpression) {
            let digits = text[match].filter(\.isNumber)
            if let value = Double(digits), (10...90).contains(value) { convention.purityThreshold = value / 100 }
        }
        // `音乐叫歌曲库`, `图片改名为相册`: a category's own name, accepted only when it is a valid folder name.
        for category in convention.categories {
            for name in [category.chinese, category.english.lowercased()] {
                let pattern = NSRegularExpression.escapedPattern(for: name) + "\\s*(?:叫|改名为|命名为|用)\\s*[「“\"]?([^，。,;；」”\"\\s]{1,20})"
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: preference, range: NSRange(preference.startIndex..., in: preference)),
                      let range = Range(match.range(at: 1), in: preference) else { continue }
                let custom = String(preference[range])
                if ArchiveFolderNaming.problems(custom, convention: base).isEmpty,
                   convention.category(forFolderName: custom).map({ $0.id == category.id }) ?? true {
                    convention.customNames[category.id] = custom
                }
            }
        }
        return convention
    }

    /// A short description of the convention in effect, for the settings and the details panel.
    var summary: String {
        var parts = [topLevel == .category ? "按类别整理" : "按项目整理", language == .chinese ? "中文类别名" : "英文类别名",
                     "词之间用“\(wordSeparator == .hyphen ? "-" : "空格")”", "混合阈值 \(Int(purityThreshold * 100))%"]
        if !customNames.isEmpty {
            parts.append(customNames.sorted { $0.key < $1.key }.map { "\(category($0.key)?.chinese ?? $0.key)→\($0.value)" }.joined(separator: "、"))
        }
        return parts.joined(separator: " · ")
    }
}
