//
//  WorkspaceView.swift
//  inchspace
//
//  本文件构建右侧工作区、工具卡片和工具占位详情，并定义内容层的视觉层级。
//

import SwiftUI

struct WorkspaceView: View {
    let destination: SidebarDestination
    let searchText: String

    /// 判断当前是否正在执行全局工具搜索。
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 返回当前页面需要显示的工具。
    private var displayedTools: [ToolDefinition] {
        if isSearching {
            ToolCatalog.search(matching: searchText)
        } else {
            ToolCatalog.tools(for: destination)
        }
    }

    /// 返回当前内容区的标题。
    private var pageTitle: String {
        isSearching ? "搜索结果" : destination.title
    }

    /// 构建工作区主页面。
    /// - Returns: 包含背景、页面标题和自适应工具网格的内容视图。
    var body: some View {
        ZStack {
            WorkspaceBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if destination == .workspace && !isSearching {
                        WorkspaceHero()
                    }

                    ToolGridSection(
                        title: pageTitle,
                        subtitle: pageSubtitle,
                        tools: displayedTools,
                        searchText: searchText
                    )
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .navigationTitle(pageTitle)
    }

    /// 返回当前页面标题下方的辅助说明。
    private var pageSubtitle: String {
        if isSearching {
            return "在全部工具中查找与“\(searchText)”相关的结果"
        }

        switch destination {
        case .workspace:
            return "选择一个工具开始处理"
        case .favorites:
            return "集中查看你经常使用的工具"
        case .recents:
            return "继续最近的处理流程"
        case .text:
            return "清理、转换和检查文本内容"
        case .image:
            return "处理图片尺寸、体积与颜色"
        case .conversion:
            return "在常见数据格式和单位之间转换"
        case .developer:
            return "面向开发工作的轻量辅助工具"
        }
    }
}

/// 展示工作台的主要介绍和快速开始入口。
private struct WorkspaceHero: View {
    /// 构建工作台头部内容。
    /// - Returns: 带有品牌渐变和 Liquid Glass 主按钮的介绍卡片。
    var body: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Text("你的轻量工具空间")
                    .font(.system(.largeTitle, design: .default, weight: .semibold))

                Text("把常用的小工具放在一个安静、快速且始终顺手的位置。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 主操作使用系统玻璃按钮；内容卡片本身保持在普通内容层。
                NavigationLink(value: ToolCatalog.quickStart) {
                    Label("快速开始", systemImage: "arrow.right")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.top, 6)
            }

            Spacer(minLength: 24)

            Image(systemName: "square.3.layers.3d")
                .font(.system(.largeTitle, design: .default, weight: .light))
                .imageScale(.large)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
        }
        .padding(30)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.20),
                            Color.accentColor.opacity(0.07),
                            Color.purple.opacity(0.05),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

/// 展示页面标题以及自适应工具卡片网格。
private struct ToolGridSection: View {
    let title: String
    let subtitle: String
    let tools: [ToolDefinition]
    let searchText: String

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16),
    ]

    /// 构建工具网格区域。
    /// - Returns: 有结果时显示卡片网格，无结果时显示系统空状态。
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.semibold))

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if tools.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(tools) { tool in
                        NavigationLink(value: tool) {
                            ToolCard(tool: tool)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// 展示单个工具的名称、说明和图标。
private struct ToolCard: View {
    let tool: ToolDefinition
    @State private var isHovering = false

    /// 构建可响应指针悬停的工具卡片。
    /// - Returns: 使用标准内容材质、而非 Liquid Glass 的工具入口。
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Image(systemName: tool.systemImage)
                    .font(.headline)
                    .imageScale(.medium)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(tool.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(tool.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .padding(18)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    Color.primary.opacity(isHovering ? 0.14 : 0.06),
                    lineWidth: 1
                )
        }
        .shadow(
            color: Color.black.opacity(isHovering ? 0.08 : 0.03),
            radius: isHovering ? 14 : 7,
            y: isHovering ? 6 : 3
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.smooth(duration: 0.18), value: isHovering)
    }
}

/// 为右侧内容提供可延伸到系统侧栏下方的低对比背景。
private struct WorkspaceBackground: View {
    /// 构建适配浅色和深色外观的内容背景。
    /// - Returns: 使用语义背景色和少量强调色的渐变视图。
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)

            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.09),
                    Color.clear,
                    Color.purple.opacity(0.035),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        // 让色彩延伸至悬浮侧栏下方，形成系统推荐的内容穿透效果。
        .backgroundExtensionEffect()
        .ignoresSafeArea()
    }
}

/// 展示工具详情页的基础状态，后续真实功能可以在此位置逐项接入。
struct ToolDetailView: View {
    let tool: ToolDefinition

    /// 构建工具详情占位页面。
    /// - Returns: 包含工具身份、用途说明和当前开发状态的详情视图。
    var body: some View {
        ZStack {
            WorkspaceBackground()

            VStack(spacing: 18) {
                Image(systemName: tool.systemImage)
                    .font(.largeTitle.weight(.medium))
                    .imageScale(.large)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                Text(tool.title)
                    .font(.largeTitle.weight(.semibold))

                Text(tool.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Label("界面入口已就绪，功能将在后续步骤接入", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .multilineTextAlignment(.center)
            .padding(40)
        }
        .navigationTitle(tool.title)
    }
}

#Preview {
    NavigationStack {
        WorkspaceView(destination: .workspace, searchText: "")
    }
    .frame(width: 860, height: 700)
}
