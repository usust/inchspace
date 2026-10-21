import AppKit
import SwiftUI

struct AppLanguageView: View {
    @StateObject private var model = AppLanguageViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header

            HSplitView {
                applicationList.frame(minWidth: 240, idealWidth: 290, maxWidth: 360)
                ScrollView {
                    if let app = model.selectedApp {
                        detail(app)
                            .padding(AppLayout.pagePadding)
                            .frame(maxWidth: AppLayout.contentMaxWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .top)
                    } else {
                        ContentUnavailableView("选择一个应用", systemImage: "character.bubble")
                            .frame(maxWidth: .infinity, minHeight: 360)
                    }
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { if model.applications.isEmpty { await model.refresh() } }
        .onChange(of: model.selection) { _, _ in model.loadPreference() }
        .alert("应用语言", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                headerTitle
                Spacer(minLength: 16)
                headerActions
            }
            VStack(alignment: .leading, spacing: 14) {
                headerTitle
                headerActions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appFeatureHeaderBackground()
    }

    private var headerTitle: some View {
        AppFeatureTitle("应用语言")
            .fixedSize(horizontal: true, vertical: false)
    }

    private var headerActions: some View {
        HStack(spacing: 12) {
            if model.isScanning {
                ProgressView().controlSize(.small).accessibilityLabel("正在扫描应用")
            }
            Button("添加应用", systemImage: "plus", action: model.addApplication)
            Button("重新扫描", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .help("重新扫描应用目录与 Spotlight 索引")
        }
        .buttonStyle(.bordered)
        .disabled(model.isBusy || model.isScanning)
    }

    private var applicationList: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.filteredApplications) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable().frame(width: 32, height: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name)
                                .fontWeight(model.selection == app.id ? .semibold : .regular)
                                .lineLimit(1)
                            Text(app.languages.isEmpty ? "未声明语言" : "\(app.languages.count) 种语言")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    .tag(app.id)
                    .help(app.url.path)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.filteredApplications.isEmpty {
                    ContentUnavailableView(model.isScanning ? "正在发现应用" : "没有找到应用",
                                           systemImage: "magnifyingglass",
                                           description: Text(model.isScanning ? "正在读取本机应用信息…" : "尝试切换分类、修改关键词或添加应用。"))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                listControls.padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
            }
            HStack(spacing: 8) {
                Text(model.filter.title)
                Spacer()
                Text("\(model.filteredApplications.count) / \(model.applications.count) 个应用")
                    .monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .disabled(model.isBusy)
    }

    private var listControls: some View {
        VStack(spacing: 10) {
            Picker("应用来源", selection: $model.filter) {
                ForEach(AppLanguageFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                        .accessibilityLabel(filter.accessibilityTitle)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("按应用来源筛选")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("搜索名称、标识或路径", text: $model.search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("搜索应用")
                if !model.search.isEmpty {
                    Button {
                        model.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 9))
        }
        .padding(10)
        .appSurface()
    }

    @ViewBuilder
    private func languageActions(_ app: LanguageApplication) -> some View {
        let hasChanges = model.selectedLanguage != model.savedLanguage
        let unavailableReason = AppLanguageRestartService.unavailableReason(for: app)
        Button("仅保存") { Task { await model.save() } }
            .buttonStyle(.bordered)
            .disabled(!model.preferenceReadable || !hasChanges)
        Button {
            Task {
                if hasChanges { await model.save(restart: true) }
                else { await model.restartSelectedApplication() }
            }
        } label: {
            Label(model.isRestarting ? "正在重启…" : (hasChanges ? "保存并重启" : "重启应用"), systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .disabled(unavailableReason != nil || !model.preferenceReadable)
        .help(unavailableReason ?? "正常退出并重新打开应用；未运行时直接打开。")
    }

    private func detail(_ app: LanguageApplication) -> some View {
        VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
            applicationIdentity(app)
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("界面语言", systemImage: "globe").font(.headline)
                    Spacer()
                    if model.selectedLanguage != model.savedLanguage {
                        Text("未保存").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("当前设置：\(model.savedLanguage.isEmpty ? "跟随系统" : LanguageApplication.languageName(model.savedLanguage))")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("显示语言", selection: $model.selectedLanguage) {
                    Text("跟随系统").tag("")
                    if !model.savedLanguage.isEmpty && !app.languages.contains(model.savedLanguage) {
                        Text("\(LanguageApplication.languageName(model.savedLanguage))（现有设置）").tag(model.savedLanguage)
                    }
                    ForEach(app.languages, id: \.self) { code in
                        Text("\(LanguageApplication.languageName(code)) · \(code)").tag(code)
                    }
                }
                .controlSize(.large)
                .disabled(!model.preferenceReadable || model.isBusy || model.isScanning)
                Button("恢复跟随系统") { model.selectedLanguage = "" }
                    .buttonStyle(.link)
                    .disabled(model.selectedLanguage.isEmpty || !model.preferenceReadable || model.isBusy || model.isScanning)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { languageActions(app) }
                    VStack(alignment: .leading, spacing: 12) { languageActions(app) }
                }
                .disabled(model.isBusy || model.isScanning)
                if let status = model.status {
                    HStack(spacing: 8) {
                        if model.isBusy { ProgressView().controlSize(.small) }
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if app.languages.count < 2 {
                    Text("此应用未提供多语言支持。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if app.bundleIdentifier == nil {
                    Text("缺少应用标识，无法保存单应用语言设置。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if !model.warnings.isEmpty {
                Label(model.warnings.joined(separator: "\n"), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("应用位置").font(.subheadline.weight(.medium))
                Text(app.url.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("在 Finder 中显示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([app.url])
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func applicationIdentity(_ app: LanguageApplication) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable().frame(width: 56, height: 56).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(app.name).font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(app.bundleIdentifier ?? "无应用标识")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(app.isAppleApplication ? AppLanguageFilter.apple.title : AppLanguageFilter.user.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: .capsule)
                    .accessibilityLabel(app.isAppleApplication ? "Apple 应用" : "用户应用")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
