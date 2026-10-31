//
//  ContentView.swift
//  inchspace
//
//  Created by lyu on 8/3/26.
//
//  应用根视图：组织可折叠侧栏和空白详情区。

import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject private var updateManager: UpdateManager
    @StateObject private var repository: LaunchpadRepository
    @StateObject private var runnerStore: RunnerStore
    @StateObject private var serverManager: ServerManager
    @StateObject private var terminalManager: TerminalManager
    @StateObject private var remoteFileModel: RemoteFileViewModel
    @StateObject private var archiveModel = ArchiveViewModel.shared
    private let environmentService: EnvironmentVariableService
    @State private var selection: SidebarDestination? = .workspace
    @State private var settingsTab: SettingsTab = .general
    @Environment(\.scenePhase) private var scenePhase

    init(updateManager: UpdateManager) {
        self.updateManager = updateManager
        environmentService = EnvironmentVariableService()
        _repository = StateObject(wrappedValue: LaunchpadRepository())
        _runnerStore = StateObject(wrappedValue: RunnerStore())
        _serverManager = StateObject(wrappedValue: ServerManager())
        _terminalManager = StateObject(wrappedValue: TerminalManager())
        _remoteFileModel = StateObject(wrappedValue: RemoteFileViewModel())
    }

    var body: some View {
        NavigationSplitView {
            AppSidebar(selection: $selection)
        } detail: {
            detailView
                .background(AppPageBackground())
        }
        .navigationSplitViewStyle(.balanced)
        .onReceive(NotificationCenter.default.publisher(for: .inchspaceOpenSettings)) { notification in
            if let rawValue = notification.userInfo?["tab"] as? String,
               let requestedTab = SettingsTab(rawValue: rawValue) {
                settingsTab = requestedTab
            }
            selection = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .inchspaceSelectTerminal)) { _ in
            selection = .terminal
        }
        .onAppear { configureTerminalIntegration() }
        .task { await runnerStore.bootstrap() }
        .task { _ = environmentService.reloadEnvironment() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active { repository.saveImmediately() }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        let destination = selection ?? .workspace
        switch destination {
        case .workspace:
            WorkbenchView(repository: repository)
        case .appRepair:
            AppRepairView()
        case .appLanguage:
            AppLanguageView()
        case .autoArchive:
            ArchiveView(model: archiveModel, aiSettings: terminalManager.aiSettings)
        case .runner:
            RunnerView(store: runnerStore)
        case .servers:
            ServerManagerView(manager: serverManager)
        case .remoteFiles:
            RemoteFileView(model: remoteFileModel, serverManager: serverManager)
        case .environmentVariables:
            EnvironmentVariableView(service: environmentService, terminalManager: terminalManager)
        case .terminal:
            TerminalView(manager: terminalManager, serverManager: serverManager)
        case .developer:
            DeveloperToolsView()
        case .text, .image, .conversion:
            ContentUnavailableView(
                destination.title,
                systemImage: destination.systemImage,
                description: Text("此工具区域将在后续版本中提供。")
            )
        case .settings:
            SettingsView(repository: repository, updateManager: updateManager, terminalManager: terminalManager, selectedCategory: $settingsTab)
        }
    }

    private func configureTerminalIntegration() {
        serverManager.terminalConnectionHandler = { [weak terminalManager, weak serverManager] server in
            guard let terminalManager, let serverManager else { return }
            let jumpHost = server.jumpHostID.flatMap { id in
                serverManager.servers.first { $0.id == id }
            }
            terminalManager.openRemoteSession(
                server: server,
                credential: serverManager.credential(for: server),
                jumpHost: jumpHost
            )
            serverManager.recordTerminalConnection(server)
            NotificationCenter.default.post(name: .inchspaceSelectTerminal, object: server.id)
        }
    }
}

extension Notification.Name {
    static let inchspaceSelectTerminal = Notification.Name("inchspace.selectTerminal")
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(updateManager: UpdateManager())
            .environmentObject(AppVisibilityController.shared)
    }
}
#endif
