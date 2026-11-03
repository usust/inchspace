import AppKit
import SwiftUI

enum PythonEnvironmentEditorMode: Identifiable {
    case add
    case create
    case edit(PythonEnvironment)

    var id: String {
        switch self {
        case .add: "add"
        case .create: "create"
        case .edit(let environment): environment.id.uuidString
        }
    }

    var title: String {
        switch self {
        case .add: "添加已有环境"
        case .create: "新建 Python 环境"
        case .edit: "编辑 Python 环境"
        }
    }
}

struct PythonEnvironmentEditor: View {
    let mode: PythonEnvironmentEditorMode
    let onSave: (PythonEnvironment) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var path = ""
    @State private var workingDirectory = ""
    @State private var interpreter = ""
    @State private var target = PythonTerminalTarget.builtIn
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var createdEnvironment: PythonEnvironment?

    private var creating: Bool { if case .create = mode { return true }; return false }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !path.isEmpty && !workingDirectory.isEmpty
            && (!creating || !interpreter.isEmpty) && !saving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(mode.title).font(.title2.bold())
            Form {
                TextField("名称", text: $name)
                directoryField("环境目录", path: $path, action: chooseEnvironment)
                    .disabled(createdEnvironment != nil)
                directoryField("工作目录", path: $workingDirectory) { chooseDirectory(binding: $workingDirectory) }
                if creating {
                    directoryField("Python 解释器", path: $interpreter, action: chooseInterpreter)
                        .disabled(createdEnvironment != nil)
                    Text("选择本机已有的 python3 可执行文件。目标环境目录必须尚不存在；使用标准 venv 创建，不自动下载 Python。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("默认终端", selection: $target) {
                    ForEach(PythonTerminalTarget.allCases) { Text($0.title).tag($0) }
                }
            }
            .formStyle(.grouped)
            Text("仅添加你信任的本地环境。检查版本和查看模块会运行该环境的 Python，打开终端会执行其激活脚本。首版支持 venv、virtualenv 和 uv 创建的标准虚拟环境，不支持 Conda。")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                if saving { ProgressView().controlSize(.small); Text(creating ? "正在创建环境…" : "正在保存…").foregroundStyle(.secondary) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(creating && createdEnvironment == nil ? "创建并添加" : "保存", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(24).frame(width: 620)
        .interactiveDismissDisabled(saving)
        .onAppear {
            if case .edit(let environment) = mode {
                name = environment.name
                path = environment.path
                workingDirectory = environment.workingDirectory
                target = environment.terminalTarget
            }
        }
    }

    private func directoryField(_ title: String, path: Binding<String>, action: @escaping () -> Void) -> some View {
        HStack {
            TextField(title, text: path)
            Button("选择…", action: action)
        }.disabled(saving)
    }

    private func chooseDirectory(binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { binding.wrappedValue = url.path }
    }

    private func chooseEnvironment() {
        if creating {
            let panel = NSSavePanel()
            panel.title = "选择新环境的位置"
            panel.nameFieldStringValue = ".venv"
            panel.canCreateDirectories = true
            panel.showsHiddenFiles = true
            if panel.runModal() == .OK, let url = panel.url { setEnvironmentPath(url) }
        } else {
            let panel = NSOpenPanel()
            panel.title = "选择虚拟环境目录（例如 .venv）"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.showsHiddenFiles = true
            if panel.runModal() == .OK, let url = panel.url { setEnvironmentPath(url) }
        }
    }

    private func setEnvironmentPath(_ url: URL) {
        path = url.path
        if name.isEmpty { name = url.lastPathComponent.hasPrefix(".") ? url.deletingLastPathComponent().lastPathComponent : url.lastPathComponent }
        if workingDirectory.isEmpty { workingDirectory = url.deletingLastPathComponent().path }
    }

    private func chooseInterpreter() {
        let panel = NSOpenPanel()
        panel.title = "选择本机 Python 3 解释器"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/usr/bin")
        if panel.runModal() == .OK, let url = panel.url { interpreter = url.path }
    }

    private func save() {
        saving = true
        errorMessage = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                let environment: PythonEnvironment
                if creating {
                    if var createdEnvironment {
                        createdEnvironment.name = name
                        createdEnvironment.workingDirectory = expanded(workingDirectory)
                        createdEnvironment.terminalTarget = target
                        environment = createdEnvironment
                    } else {
                        environment = try await PythonEnvironmentService.create(
                            name: name, at: expanded(path), interpreter: expanded(interpreter),
                            workingDirectory: expanded(workingDirectory), terminalTarget: target
                        )
                        createdEnvironment = environment
                    }
                } else {
                    var value = PythonEnvironment(name: name, path: expanded(path), workingDirectory: expanded(workingDirectory), terminalTarget: target)
                    if case .edit(let existing) = mode { value.id = existing.id }
                    try PythonEnvironmentService.validate(value)
                    environment = value
                }
                try onSave(environment)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                if let createdEnvironment {
                    errorMessage = "环境已创建在 \(createdEnvironment.path)，但保存记录失败：\(error.localizedDescription)。可重试保存或稍后使用“添加已有”。"
                }
            }
        }
    }

    private func expanded(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

struct PythonDiscoverySheet: View {
    let environments: [PythonEnvironment]
    let existing: [PythonEnvironment]
    let onAdd: (PythonEnvironment) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var added = Set<String>()
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("发现的 Python 环境").font(.title2.bold())
            Text("扫描只检查目录结构，不执行代码。只添加你信任的环境；选中已添加的环境时会运行其 Python 检查版本。扫描范围有深度和数量限制，未找到的环境可以手动添加。")
                .font(.callout).foregroundStyle(.secondary)
            if environments.isEmpty {
                ContentUnavailableView("未发现标准虚拟环境", systemImage: "magnifyingglass", description: Text("请选择更接近项目的目录，或直接添加已有环境。"))
            } else {
                List(environments) { environment in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(environment.name).font(.headline)
                            Text(environment.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button(isAdded(environment) ? "已添加" : "添加") {
                            do { try onAdd(environment); added.insert(environment.path) }
                            catch { errorMessage = error.localizedDescription }
                        }.disabled(isAdded(environment))
                    }.padding(.vertical, 6)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 640, height: 460)
    }

    private func isAdded(_ environment: PythonEnvironment) -> Bool {
        added.contains(environment.path) || existing.contains {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == URL(fileURLWithPath: environment.path).resolvingSymlinksInPath()
        }
    }
}
