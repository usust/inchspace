//
//  ContentView.swift
//  inchspace
//
//  Created by lyu on 8/3/26.
//
//  应用根视图：组织可折叠侧栏、内容导航和全局工具搜索。

import SwiftUI

struct ContentView: View {
    @State private var selectedDestination: SidebarDestination? = .workspace
    @State private var searchText = ""

    /// 构建应用的根界面。
    /// - Returns: 包含侧栏、内容区和全局搜索入口的分栏视图。
    var body: some View {
        // 使用系统分栏组件，让侧栏自动获得 macOS 26 的 Liquid Glass 与折叠行为。
        NavigationSplitView {
            AppSidebar(selection: $selectedDestination)
        } detail: {
            NavigationStack {
                WorkspaceView(
                    destination: selectedDestination ?? .workspace,
                    searchText: searchText
                )
                .navigationDestination(for: ToolDefinition.self) { tool in
                    ToolDetailView(tool: tool)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索工具")
    }
}

#Preview {
    ContentView()
}
