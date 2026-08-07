//
//  SidebarDestination.swift
//  inchspace
//
//  本文件定义侧栏入口及其显示信息。
//

/// 描述应用侧栏中的一级导航入口。
enum SidebarDestination: String, Identifiable {
    case workspace
    case text
    case image
    case conversion
    case developer
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspace: "启动台"
        case .text: "文本处理"
        case .image: "图片工具"
        case .conversion: "格式转换"
        case .developer: "开发工具"
        case .settings: "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .workspace: "square.grid.2x2"
        case .text: "textformat"
        case .image: "photo.on.rectangle"
        case .conversion: "arrow.left.arrow.right"
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .settings: "gearshape"
        }
    }

    static let libraryItems: [SidebarDestination] = [
        .workspace,
    ]

    static let toolItems: [SidebarDestination] = [
        .text,
        .image,
        .conversion,
        .developer,
    ]
}
