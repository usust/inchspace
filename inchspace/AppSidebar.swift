//
//  AppSidebar.swift
//  inchspace
//
//  本文件构建应用左侧导航菜单，并通过绑定把用户选择同步给根视图。
//

import SwiftUI

struct AppSidebar: View {
    @Binding var selection: SidebarDestination?

    /// 构建应用侧栏。
    /// - Returns: 采用 macOS 原生侧栏样式的分组导航列表。
    var body: some View {
        List(selection: $selection) {
            Section("空间") {
                ForEach(SidebarDestination.libraryItems) { destination in
                    sidebarRow(for: destination)
                }
            }

            Section("工具") {
                ForEach(SidebarDestination.toolItems) { destination in
                    sidebarRow(for: destination)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("InchSpace")
        .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 280)
    }

    /// 创建一个侧栏导航行。
    /// - Parameter destination: 导航行所代表的目标页面。
    /// - Returns: 带有系统图标、标题和选择标识的侧栏行。
    private func sidebarRow(for destination: SidebarDestination) -> some View {
        Label(destination.title, systemImage: destination.systemImage)
            .tag(destination)
    }
}

#Preview {
    @Previewable @State var selection: SidebarDestination? = .workspace

    NavigationSplitView {
        AppSidebar(selection: $selection)
    } detail: {
        Text(selection?.title ?? "未选择")
    }
}
