import Foundation

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case terminal
    case ai
    case sync
    case updates

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .terminal: "terminal"
        case .ai: "sparkles"
        case .sync: "icloud"
        case .updates: "arrow.down.circle"
        }
    }

    var title: String {
        switch self {
        case .general: "通用"
        case .terminal: "终端"
        case .ai: "AI"
        case .sync: "同步"
        case .updates: "更新"
        }
    }
}
