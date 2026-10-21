//
//  AppSidebar.swift
//  inchspace
//
//  本文件构建应用左侧导航菜单。
//

import SwiftUI

struct AppSidebar: View {
    @Binding var selection: SidebarDestination?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AppIconTile(symbol: "square.stack.3d.up", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("寸空间").font(.headline)
                    Text("你的 Mac 工作空间")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)

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

                Section {
                    ForEach(SidebarDestination.terminalItems) { destination in
                        sidebarRow(for: destination)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button {
                selection = .settings
            } label: {
                Label {
                    Text(SidebarDestination.settings.title)
                } icon: {
                    Image(systemName: SidebarDestination.settings.systemImage)
                        .frame(width: 20)
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(
                        selection == .settings ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }
            .buttonStyle(AppCardButtonStyle())
            .fontWeight(selection == .settings ? .semibold : .regular)
            .accessibilityAddTraits(selection == .settings ? .isSelected : [])
            .padding(12)
        }
        .animation(reduceMotion ? nil : AppMotion.feedback, value: selection)
        .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
    }

    private func sidebarRow(for destination: SidebarDestination) -> some View {
        Label {
            Text(destination.title)
        } icon: {
            Image(systemName: destination.systemImage)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 20)
        }
            .font(.system(size: 13))
            .fontWeight(selection == destination ? .semibold : .regular)
            .padding(.vertical, 4)
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
