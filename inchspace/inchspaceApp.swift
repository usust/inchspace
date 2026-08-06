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
    /// 构建应用的主场景。
    /// - Returns: 包含 `ContentView` 的主窗口场景。
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1180, minHeight: 800)
        }
        // 为桌面工具提供舒适的初始工作区，同时仍允许用户自由调整窗口。
        .defaultSize(width: 1180, height: 800)
        .windowResizability(.contentMinSize)
    }
}
