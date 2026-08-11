//
//  inchspaceApp.swift
//  inchspace
//
//  Created by lyu on 8/3/26.
//
//  应用启动入口：创建主窗口并加载根视图。

import SwiftUI

@main
struct inchspaceApp: App {
    @NSApplicationDelegateAdaptor(InchspaceApplicationDelegate.self) private var appDelegate
    @StateObject private var updateManager = UpdateManager()
    @StateObject private var visibilityController = AppVisibilityController.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(updateManager: updateManager)
                .frame(minWidth: 1180, minHeight: 800)
                .environmentObject(visibilityController)
                .background(MainWindowBridge(controller: visibilityController))
                .background(WindowOpeningBridge(controller: visibilityController))
        }
        .defaultSize(width: 1180, height: 800)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    visibilityController.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    updateManager.checkForUpdates()
                }
                .disabled(!updateManager.canCheckForUpdates)
            }
        }
    }
}
