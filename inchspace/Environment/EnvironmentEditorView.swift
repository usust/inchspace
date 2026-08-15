import AppKit
import SwiftUI

struct EnvironmentEditorView: View {
    enum Destination: String, CaseIterable, Identifiable {
        case automatic
        case zprofile
        case zshrc

        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: "自动选择"
            case .zprofile: "~/.zprofile"
            case .zshrc: "~/.zshrc"
            }
        }
    }

    let variable: EnvironmentVariable?
    let source: EnvironmentVariableSource?
    let service: EnvironmentVariableService
    let onSave: (String, String, URL?, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var value: String
    @State private var destination: Destination = .automatic
    @State private var exportToPath: Bool
    @FocusState private var focusedField: Field?

    private enum Field { case name, value }
    private let templates = ["JAVA_HOME", "ANDROID_HOME", "GOPATH", "GRADLE_HOME", "MAVEN_HOME"]

    init(
        variable: EnvironmentVariable?,
        source: EnvironmentVariableSource? = nil,
        service: EnvironmentVariableService,
        onSave: @escaping (String, String, URL?, Bool) -> Void
    ) {
        self.variable = variable
        self.source = source
        self.service = service
        self.onSave = onSave
        _name = State(initialValue: variable?.name ?? "")
        _value = State(initialValue: source?.value ?? variable?.effectiveValue ?? "")
        _exportToPath = State(initialValue: source?.isExportedToPath ?? false)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isNameValid: Bool { EnvironmentVariableService.isValidVariableName(trimmedName) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(variable == nil ? "新建环境变量" : "编辑 \(variable?.name ?? "")")
                        .font(.title2.weight(.semibold))
                    Text(source?.displayName ?? "应用中新启动的工具会立即使用最新值")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(22)
            .background(.ultraThinMaterial.opacity(0.72))

            Form {
                Section("变量") {
                    TextField("变量名称", text: $name)
                        .focused($focusedField, equals: .name)
                        .disabled(variable != nil)
                    if !name.isEmpty, !isNameValid {
                        Label("名称只能包含字母、数字和下划线，且不能以数字开头", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        TextField("变量值", text: $value)
                            .focused($focusedField, equals: .value)
                        Button("选择目录…") { chooseDirectory() }
                    }
                }

                if variable == nil {
                    Section("常用变量") {
                        HStack(spacing: 7) {
                            ForEach(templates, id: \.self) { template in
                                Button(template) { name = template; focusedField = .value }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                Section("保存位置") {
                    Picker("配置文件", selection: $destination) {
                        ForEach(Destination.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(variable != nil)
                    Text(destination == .automatic
                         ? (source.map { "将修改 \($0.displayName) 中的定义。" } ?? "新变量默认保存到 ~/.zprofile。")
                         : "将直接保存到 \(destination.title)。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("终端命令") {
                    Toggle("同时加入 PATH", isOn: $exportToPath)
                        .disabled(trimmedName == "PATH")
                    Text("启用后，可以直接运行该目录内的命令；重复加载配置不会产生重复 PATH。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("不会修改已运行的外部终端进程")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存并应用") { onSave(trimmedName, value, destinationURL, exportToPath) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isNameValid)
            }
            .padding(18)
            .background(.ultraThinMaterial.opacity(0.66))
        }
        .frame(width: 620, height: 490)
        .background(.regularMaterial)
        .onAppear { focusedField = variable == nil ? .name : .value }
    }

    private var destinationURL: URL? {
        switch destination {
        case .automatic: nil
        case .zprofile: service.homeDirectory.appending(path: ".zprofile")
        case .zshrc: service.homeDirectory.appending(path: ".zshrc")
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url { value = url.path }
    }
}
