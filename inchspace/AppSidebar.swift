//
//  AppSidebar.swift
//  inchspace
//
//  本文件构建应用左侧导航菜单。
//

import SwiftUI

struct AppSidebar: View {
    @Binding var selection: SidebarDestination?

    var body: some View {
        VStack(spacing: 0) {
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

                Section("运行") {
                    ForEach(SidebarDestination.runtimeItems) { destination in
                        sidebarRow(for: destination)
                    }
                }

                Section("管理") {
                    ForEach(SidebarDestination.managementItems) { destination in
                        sidebarRow(for: destination)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button {
                selection = .settings
            } label: {
                Label(SidebarDestination.settings.title, systemImage: SidebarDestination.settings.systemImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(
                        selection == .settings ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 280)
    }

    private func sidebarRow(for destination: SidebarDestination) -> some View {
        Label(destination.title, systemImage: destination.systemImage)
            .tag(destination)
    }
}

private struct AppSidebarPreview: View {
    @State private var selection: SidebarDestination? = .workspace

    var body: some View {
        NavigationSplitView {
            AppSidebar(selection: $selection)
        } detail: {
            Color.clear
        }
    }
}

#if DEBUG
struct AppSidebar_Previews: PreviewProvider {
    static var previews: some View { AppSidebarPreview() }
}
#endif
