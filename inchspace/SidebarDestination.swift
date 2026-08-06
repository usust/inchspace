//
//  SidebarDestination.swift
//  inchspace
//
//  本文件定义侧栏入口和工具展示数据，为导航与页面内容提供统一的数据来源。
//

import Foundation

/// 描述应用侧栏中的一级导航入口。
enum SidebarDestination: String, CaseIterable, Identifiable {
    case workspace
    case favorites
    case recents
    case text
    case image
    case conversion
    case developer

    /// 为 SwiftUI 列表提供稳定标识。
    var id: String { rawValue }

    /// 返回入口在侧栏和页面标题中显示的名称。
    var title: String {
        switch self {
        case .workspace: "工作台"
        case .favorites: "收藏"
        case .recents: "最近使用"
        case .text: "文本处理"
        case .image: "图片工具"
        case .conversion: "格式转换"
        case .developer: "开发工具"
        }
    }

    /// 返回与入口含义对应的 SF Symbol 名称。
    var systemImage: String {
        switch self {
        case .workspace: "square.grid.2x2"
        case .favorites: "star"
        case .recents: "clock"
        case .text: "textformat"
        case .image: "photo.on.rectangle"
        case .conversion: "arrow.left.arrow.right"
        case .developer: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// 返回侧栏“空间”分组中的入口。
    static let libraryItems: [SidebarDestination] = [
        .workspace,
        .favorites,
        .recents,
    ]

    /// 返回侧栏“工具”分组中的入口。
    static let toolItems: [SidebarDestination] = [
        .text,
        .image,
        .conversion,
        .developer,
    ]
}

/// 描述一个可在工作台中展示和导航的工具。
struct ToolDefinition: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let systemImage: String
    let category: SidebarDestination
    let isFavorite: Bool
    let isRecent: Bool
}

/// 提供当前界面使用的工具目录；后续接入真实功能时可替换为持久化数据。
enum ToolCatalog {
    static let all: [ToolDefinition] = [
        ToolDefinition(
            id: "clean-text",
            title: "文本清理",
            summary: "整理空格、换行和不可见字符",
            systemImage: "textformat",
            category: .text,
            isFavorite: false,
            isRecent: true
        ),
        ToolDefinition(
            id: "json-formatter",
            title: "JSON 格式化",
            summary: "格式化、压缩并检查 JSON 内容",
            systemImage: "curlybraces",
            category: .developer,
            isFavorite: true,
            isRecent: true
        ),
        ToolDefinition(
            id: "image-compressor",
            title: "图片压缩",
            summary: "减小图片体积并保持清晰度",
            systemImage: "photo.on.rectangle",
            category: .image,
            isFavorite: true,
            isRecent: true
        ),
        ToolDefinition(
            id: "color-picker",
            title: "颜色取样",
            summary: "读取颜色并转换常用色彩格式",
            systemImage: "eyedropper",
            category: .image,
            isFavorite: false,
            isRecent: false
        ),
        ToolDefinition(
            id: "unit-converter",
            title: "单位换算",
            summary: "快速转换长度、面积和重量单位",
            systemImage: "ruler",
            category: .conversion,
            isFavorite: true,
            isRecent: false
        ),
        ToolDefinition(
            id: "timestamp-converter",
            title: "时间戳转换",
            summary: "在时间戳与本地日期之间转换",
            systemImage: "clock.arrow.circlepath",
            category: .conversion,
            isFavorite: false,
            isRecent: false
        ),
        ToolDefinition(
            id: "url-codec",
            title: "URL 编解码",
            summary: "编码或还原 URL 中的特殊字符",
            systemImage: "link",
            category: .developer,
            isFavorite: false,
            isRecent: false
        ),
        ToolDefinition(
            id: "case-converter",
            title: "大小写转换",
            summary: "转换标题、驼峰与下划线格式",
            systemImage: "character.cursor.ibeam",
            category: .text,
            isFavorite: false,
            isRecent: false
        ),
    ]

    /// 返回工作台主操作默认打开的工具。
    static let quickStart = all[0]

    /// 根据侧栏入口筛选需要展示的工具。
    /// - Parameter destination: 当前选中的侧栏入口。
    /// - Returns: 与入口对应的工具列表。
    static func tools(for destination: SidebarDestination) -> [ToolDefinition] {
        switch destination {
        case .workspace:
            Array(all.prefix(6))
        case .favorites:
            all.filter(\.isFavorite)
        case .recents:
            all.filter(\.isRecent)
        case .text, .image, .conversion, .developer:
            all.filter { $0.category == destination }
        }
    }

    /// 根据用户输入在全部工具的名称和说明中搜索。
    /// - Parameter query: 搜索框中的文本；首尾空白会被忽略。
    /// - Returns: 名称或说明包含查询文本的工具列表。
    static func search(matching query: String) -> [ToolDefinition] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedQuery.isEmpty else {
            return []
        }

        return all.filter { tool in
            tool.title.localizedCaseInsensitiveContains(normalizedQuery)
                || tool.summary.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }
}
