//
//  ContentView.swift
//  inchspace
//
//  Created by lyu on 8/3/26.
//
//  应用根视图：组织可折叠侧栏和空白详情区。

import SwiftUI

struct ContentView: View {
    @StateObject private var syncManager: ICloudSyncManager
    @StateObject private var repository: LaunchpadRepository
    @State private var selection: SidebarDestination? = .workspace
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let syncManager = ICloudSyncManager()
        _syncManager = StateObject(wrappedValue: syncManager)
        _repository = StateObject(wrappedValue: LaunchpadRepository(syncManager: syncManager))
    }

    var body: some View {
        NavigationSplitView {
            AppSidebar(selection: $selection)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await repository.startCloudSync()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await repository.refreshCloudData() }
            } else {
                repository.saveImmediately()
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        let destination = selection ?? .workspace
        switch destination {
        case .workspace:
            WorkbenchView(repository: repository)
        case .text, .image, .conversion, .developer:
            ContentUnavailableView(
                destination.title,
                systemImage: destination.systemImage,
                description: Text("此工具区域将在后续版本中提供。")
            )
        case .settings:
            SettingsView(syncManager: syncManager) {
                Task { await repository.startCloudSync() }
            }
        }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
#endif
