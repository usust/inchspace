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
    case runner
    case servers
    case environmentVariables
    case terminal
    case appRepair
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspace: "启动台"
        case .text: "文本处理"
        case .image: "图片工具"
        case .conversion: "格式转换"
        case .developer: "开发工具"
        case .runner: "运行中心"
        case .servers: "服务器"
        case .environmentVariables: "环境变量"
        case .terminal: "终端"
        case .appRepair: "应用修复"
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
        case .runner: "play.circle"
        case .servers: "server.rack"
        case .environmentVariables: "curlybraces"
        case .terminal: "terminal"
        case .appRepair: "wrench.and.screwdriver"
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
        .appRepair,
    ]

    static let runtimeItems: [SidebarDestination] = [
        .runner,
    ]

    static let managementItems: [SidebarDestination] = [
        .servers,
        .environmentVariables,
    ]

    static let terminalItems: [SidebarDestination] = [
        .terminal,
    ]
}
