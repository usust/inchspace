//
//  UpdateSettingsSection.swift
//  inchspace
//

import AppKit
import SwiftUI

struct UpdateSettingsSection: View {
    @ObservedObject var updateManager: UpdateManager

    var body: some View {
        Section("关于与更新") {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(AppVersion.appName)
                        .font(.headline)
                    Text("版本 \(AppVersion.displayVersion)")
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 20)

                Button {
                    updateManager.checkForUpdates()
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!updateManager.canCheckForUpdates)
            }
            .padding(.vertical, 4)

            Toggle(isOn: Binding(
                get: { updateManager.automaticallyChecksForUpdates },
                set: { updateManager.setAutomaticallyChecksForUpdates($0) }
            )) {
                SettingsPreferenceLabel(
                    title: "自动检查更新",
                    description: "定期检查是否有可用的新版本",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .disabled(!updateManager.isConfigured)

            if !updateManager.isConfigured {
                Text("当前版本暂不支持在线更新。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
