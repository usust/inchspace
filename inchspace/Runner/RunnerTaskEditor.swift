import AppKit
import SwiftUI

struct RunnerTaskEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RunnerTask
    @State private var portText: String
    @State private var errorMessage: String?
    let onSave: (RunnerTask) -> Void

    init(task: RunnerTask?, onSave: @escaping (RunnerTask) -> Void) {
        _draft = State(initialValue: task ?? RunnerTask(
            name: "",
            command: "",
            workingDirectoryPath: "",
            launchMode: .temporary,
            environment: []
        ))
        _portText = State(initialValue: task?.port.map(String.init) ?? "")
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.name.isEmpty ? "添加任务" : "编辑任务").font(.title2.weight(.bold))
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    field("名称", hint: "例如：我的 API 服务") {
                        TextField("我的 API 服务", text: $draft.name).textFieldStyle(.roundedBorder)
                    }
                    field("运行内容", hint: "填写项目原本使用的启动命令；运行时不会显示终端窗口。") {
                        TextField("例如：go run main.go", text: $draft.command)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    field("项目位置", hint: "Runner 只会访问你选择的文件夹。") {
                        HStack {
                            Text(draft.workingDirectoryPath.isEmpty ? "尚未选择" : draft.workingDirectoryPath)
                                .foregroundStyle(draft.workingDirectoryPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).frame(height: 30)
                                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                            Button("选择…", action: selectDirectory)
                        }
                    }
                    field("访问端口", hint: "可选。填写后，运行时可以一键在浏览器中打开。") {
                        TextField("例如：8080", text: $portText).textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("启动方式").font(.headline)
                        ForEach(RunnerLaunchMode.allCases) { mode in
                            Button {
                                draft.launchMode = mode
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: draft.launchMode == mode ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(draft.launchMode == mode ? Color.accentColor : Color.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(mode.title).foregroundStyle(.primary)
                                        Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(12)
                                .background(draft.launchMode == mode ? Color.accentColor.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("环境变量").font(.headline)
                            Text("可选").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("添加", systemImage: "plus") {
                                draft.environment.append(RunnerEnvironmentVariable())
                            }.buttonStyle(.borderless)
                        }
                        ForEach($draft.environment) { $variable in
                            HStack {
                                TextField("名称", text: $variable.key).textFieldStyle(.roundedBorder)
                                TextField("值", text: $variable.value).textFieldStyle(.roundedBorder)
                                Button(role: .destructive) {
                                    draft.environment.removeAll { $0.id == variable.id }
                                } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.borderless)
                            }
                        }
                        if draft.environment.isEmpty {
                            Text("仅在任务需要特殊配置时添加。敏感信息建议由系统钥匙串或项目配置提供。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 610, height: 680)
        .background(.regularMaterial)
    }

    private func field<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            content()
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择项目位置"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                draft.workingDirectoryPath = url.path
                draft.workingDirectoryBookmark = try SecurityScopedBookmarkService.makeWritableBookmark(for: url)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func save() {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.workingDirectoryPath.isEmpty else {
            errorMessage = RunnerError.invalidTask.localizedDescription
            return
        }
        draft.environment.removeAll { $0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        if portText.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.port = nil
        } else if let port = Int(portText), (1...65535).contains(port) {
            draft.port = port
        } else {
            errorMessage = "端口应为 1 到 65535 之间的数字。"
            return
        }
        onSave(draft)
        dismiss()
    }
}
