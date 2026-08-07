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
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1180, minHeight: 800)
        }
        .defaultSize(width: 1180, height: 800)
        .windowResizability(.contentMinSize)
    }
}
