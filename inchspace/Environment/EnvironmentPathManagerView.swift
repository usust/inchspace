import AppKit
import SwiftUI

struct EnvironmentPathManagerView: View {
    let service: EnvironmentVariableService
    let source: EnvironmentVariableSource
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [EnvironmentPathEntry] = []
    @State private var newPath = ""
    @State private var selectedID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PATH").font(.title2.weight(.semibold))
                    Text("拖动或使用箭头调整目录查找顺序")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(22)
            .background(.ultraThinMaterial.opacity(0.72))

            List(selection: $selectedID) {
                ForEach(entries) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.path).font(.system(.body, design: .monospaced)).lineLimit(1)
                            Label(entry.exists ? "目录存在" : "目录不存在", systemImage: entry.exists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(entry.exists ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                        }
                        Spacer()
                    }
                    .tag(entry.id)
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("复制", systemImage: "doc.on.doc") { copy(entry.path) }
                        Button("在 Finder 中显示", systemImage: "folder") { reveal(entry) }
                            .disabled(!entry.exists)
                        Divider()
                        Button("删除", role: .destructive) { entries.removeAll { $0.id == entry.id } }
                    }
                }
                .onMove { indexes, offset in entries.move(fromOffsets: indexes, toOffset: offset) }
            }
            .listStyle(.inset)

            VStack(spacing: 10) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    TextField("添加目录，例如 /opt/homebrew/bin", text: $newPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addPath)
                    Button("选择…") { chooseDirectory() }
                    Button("添加", systemImage: "plus") { addPath() }
                        .disabled(newPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    Button { moveSelected(by: -1) } label: { Label("上移", systemImage: "arrow.up") }
                        .disabled(!canMoveSelected(by: -1))
                    Button { moveSelected(by: 1) } label: { Label("下移", systemImage: "arrow.down") }
                        .disabled(!canMoveSelected(by: 1))
                    Button("删除", systemImage: "trash", role: .destructive) {
                        entries.removeAll { $0.id == selectedID }
                    }
                    .disabled(selectedID == nil)
                    Spacer()
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("保存 PATH") { save() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial.opacity(0.66))
        }
        .frame(width: 720, height: 620)
        .background(.regularMaterial)
        .onAppear { entries = service.pathEntries(from: source.value) }
    }

    private func addPath() {
        do {
            entries = try service.addPathEntry(newPath, to: entries)
            newPath = ""
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func save() {
        do {
            try service.savePathEntries(entries, destination: source.fileURL)
            onSaved()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func canMoveSelected(by offset: Int) -> Bool {
        guard let selectedID, let index = entries.firstIndex(where: { $0.id == selectedID }) else { return false }
        return entries.indices.contains(index + offset)
    }

    private func moveSelected(by offset: Int) {
        guard let selectedID, let index = entries.firstIndex(where: { $0.id == selectedID }),
              entries.indices.contains(index + offset) else { return }
        withAnimation(.smooth(duration: 0.2)) { entries.swapAt(index, index + offset) }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { newPath = url.path; addPath() }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func reveal(_ entry: EnvironmentPathEntry) {
        let path = entry.path.hasPrefix("~/")
            ? service.homeDirectory.path + String(entry.path.dropFirst())
            : entry.path
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
