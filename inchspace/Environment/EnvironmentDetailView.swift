import SwiftUI

struct EnvironmentDetailView: View {
    let variable: EnvironmentVariable
    let editableSources: [EnvironmentVariableSource]
    let onEdit: (EnvironmentVariableSource) -> Void
    let onCopy: (String) -> Void
    let onReveal: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(variable.name).font(.title2.weight(.semibold))
                    Text(variable.sources.allSatisfy(\.isProcessEnvironment)
                         ? "当前 App 启动时继承，只读"
                         : (variable.managedByApp ? "由 inchspace 管理" : "来自用户配置"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(22).background(.ultraThinMaterial.opacity(0.72))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox("当前值") {
                        HStack(alignment: .top) {
                            Text(variable.effectiveValue)
                                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button { onCopy(variable.effectiveValue) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("复制变量值")
                        }.padding(8)
                    }
                    GroupBox("来源") {
                        VStack(spacing: 0) {
                            ForEach(Array(variable.sources.enumerated()), id: \.element.id) { index, source in
                                HStack {
                                    Image(systemName: source.isProcessEnvironment ? "app" : "doc.text")
                                        .foregroundStyle(.secondary).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(source.displayName)
                                        Text(source.isProcessEnvironment ? "App 启动时继承" : "第 \(source.line ?? 0) 行")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if !source.isEnabled {
                                        Text("已禁用").font(.caption).foregroundStyle(.orange)
                                    } else if source.isExportedToPath {
                                        Text("已加入 PATH").font(.caption).foregroundStyle(Color.accentColor)
                                    } else if source.isManaged {
                                        Text("已管理").font(.caption).foregroundStyle(Color.accentColor)
                                    } else if source.isProcessEnvironment {
                                        Text("只读").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let url = source.fileURL {
                                        Button { onReveal(url) } label: { Image(systemName: "folder") }
                                            .buttonStyle(.borderless).help("在 Finder 中显示")
                                    }
                                }.padding(9)
                                if index < variable.sources.count - 1 { Divider() }
                            }
                        }
                    }
                }.padding(22)
            }

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                let enabledEditableSources = editableSources.filter(\.isEnabled)
                if enabledEditableSources.count == 1, let source = enabledEditableSources.first {
                    Button("编辑") { dismiss(); onEdit(source) }.buttonStyle(.borderedProminent)
                } else if enabledEditableSources.count > 1 {
                    Menu("编辑来源…") {
                        ForEach(enabledEditableSources) { source in
                            Button(source.displayName) { dismiss(); onEdit(source) }
                        }
                    }
                }
            }
            .padding(16).background(.ultraThinMaterial.opacity(0.66))
        }
        .frame(width: 590, height: 500)
        .background(.regularMaterial)
    }
}
