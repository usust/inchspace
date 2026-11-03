import SwiftUI

struct PythonPackagesView: View {
    let environment: PythonEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var packages: [PythonInstalledPackage] = []
    @State private var search = ""
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var refreshID = UUID()

    private var filtered: [PythonInstalledPackage] {
        packages.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.version.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("已安装模块").font(.title2.bold())
                    Text(environment.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新", systemImage: "arrow.clockwise") { refreshID = UUID() }.disabled(loading)
            }
            Text(environment.pythonPath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            TextField("搜索模块名称或版本", text: $search).textFieldStyle(.roundedBorder)
            if loading {
                VStack(spacing: 12) { ProgressView(); Text("正在读取当前环境的模块…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("无法读取模块", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage).textSelection(.enabled)
                } actions: {
                    Button("重试") { refreshID = UUID() }
                }
            } else if packages.isEmpty {
                ContentUnavailableView("尚未安装第三方包", systemImage: "shippingbox", description: Text("这是正常的空环境。你可以在该环境的终端中安装依赖，然后刷新。"))
            } else if filtered.isEmpty {
                ContentUnavailableView("没有匹配的模块", systemImage: "magnifyingglass", description: Text("请尝试其他名称或版本。"))
            } else {
                Table(filtered) {
                    TableColumn("模块 / 分发包", value: \.name)
                    TableColumn("版本", value: \.version).width(min: 100, ideal: 140, max: 200)
                }
            }
            Text("需要 Python 3.8+。读取环境中可见的第三方分发包及版本，不包含 Python 标准库；启用了系统包共享的环境也会列出共享包。此页面只读，不安装或修改依赖。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if !loading && errorMessage == nil {
                    Text(search.isEmpty ? "共 \(packages.count) 个包" : "显示 \(filtered.count) / \(packages.count) 个包")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(minWidth: 580, idealWidth: 660, minHeight: 480, idealHeight: 560)
        .task(id: refreshID) {
            loading = true
            errorMessage = nil
            packages = []
            do {
                let result = try await PythonEnvironmentService.installedPackages(environment)
                guard !Task.isCancelled else { return }
                packages = result
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            loading = false
        }
    }
}
