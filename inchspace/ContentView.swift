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
    @StateObject private var syncManager: ICloudSyncManager
    @StateObject private var repository: LaunchpadRepository
    @StateObject private var runnerStore: RunnerStore
    @StateObject private var serverManager: ServerManager
    @StateObject private var terminalManager: TerminalManager
    @StateObject private var remoteFileModel: RemoteFileViewModel
    private let environmentService: EnvironmentVariableService
    @State private var selection: SidebarDestination? = .workspace
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var visibilityController: AppVisibilityController

    init(updateManager: UpdateManager) {
        self.updateManager = updateManager
        environmentService = EnvironmentVariableService()
        let syncManager = ICloudSyncManager()
        _syncManager = StateObject(wrappedValue: syncManager)
        _repository = StateObject(wrappedValue: LaunchpadRepository(syncManager: syncManager))
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
        }
        .navigationSplitViewStyle(.balanced)
        .onReceive(NotificationCenter.default.publisher(for: .inchspaceOpenSettings)) { _ in
            selection = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .inchspaceSelectTerminal)) { _ in
            selection = .terminal
        }
        .onAppear { configureTerminalIntegration() }
        .task {
            await repository.startCloudSync()
        }
        .task {
            await synchronizePreferences(allowsUpload: true)
        }
        .task { await runnerStore.bootstrap() }
        .task { _ = environmentService.reloadEnvironment() }
        .onReceive(visibilityController.preferences.$syncedModifiedAt.dropFirst().compactMap { $0 }) { date in
            syncManager.schedulePreferencesUpload(
                visibilityController.preferences.syncedPreferences,
                modifiedAt: date
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await repository.refreshCloudData()
                    await synchronizePreferences(allowsUpload: false)
                }
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
        case .appRepair:
            AppRepairView()
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
            SettingsView(syncManager: syncManager, updateManager: updateManager, terminalManager: terminalManager) {
                Task {
                    await repository.startCloudSync()
                    await synchronizePreferences(allowsUpload: true)
                }
            }
        }
    }

    private func synchronizePreferences(allowsUpload: Bool) async {
        let preferences = visibilityController.preferences
        if let snapshot = await syncManager.synchronizePreferences(
            localPreferences: preferences.syncedPreferences,
            localModifiedAt: preferences.syncedModifiedAt,
            allowsUpload: allowsUpload
        ) {
            preferences.applySyncedPreferences(
                snapshot.preferences,
                modifiedAt: snapshot.modifiedAt
            )
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
