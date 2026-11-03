import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PythonScriptSheet: View {
    let environment: PythonEnvironment
    let onRun: (String, PythonTerminalTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scriptPath = ""
    @State private var arguments = ""
    @State private var target = PythonTerminalTarget.builtIn
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("运行 Python 脚本").font(.title2.bold())
            Text("使用“\(environment.name)”环境，在其工作目录中运行，结束后保留终端和输出。")
                .foregroundStyle(.secondary)
            HStack {
                TextField("脚本路径", text: $scriptPath)
                Button("选择…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowedContentTypes = [UTType(filenameExtension: "py") ?? .plainText]
                    if panel.runModal() == .OK, let url = panel.url { scriptPath = url.path }
                }
            }
            Text("脚本参数（可选，每行一个参数，不需要引号）").font(.headline)
            TextEditor(text: $arguments).font(.system(.body, design: .monospaced))
                .frame(height: 100).border(Color.secondary.opacity(0.2))
            Picker("运行终端", selection: $target) {
                ForEach(PythonTerminalTarget.allCases) { Text($0.title).tag($0) }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("运行", systemImage: "play") { run() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(scriptPath.isEmpty)
            }
        }.padding(24).frame(width: 580)
            .onAppear { target = environment.terminalTarget }
    }

    private func run() {
        do {
            let path = (scriptPath as NSString).expandingTildeInPath
            let command = try PythonScriptCommand.make(
                environment: environment, scriptPath: path,
                arguments: arguments.components(separatedBy: .newlines).filter { !$0.isEmpty }
            )
            onRun(command, target)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

enum PythonScriptCommand {
    static func make(environment: PythonEnvironment, scriptPath: String, arguments: [String]) throws -> String {
        var isDirectory: ObjCBool = false
        guard scriptPath.hasPrefix("/"),
              FileManager.default.fileExists(atPath: scriptPath, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: scriptPath),
              !scriptPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PythonTerminalError.invalidScript
        }
        guard !arguments.contains(where: { $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw PythonTerminalError.invalidArguments
        }
        try PythonEnvironmentService.validate(environment)
        return ([environment.pythonPath, scriptPath] + arguments).map(PythonEnvironmentService.shellQuote).joined(separator: " ")
    }
}
