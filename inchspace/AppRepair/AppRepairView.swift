//
//  AppRepairView.swift
//  inchspace
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppRepairView: View {
    @StateObject private var model = AppRepairViewModel()
    @State private var isDropTargeted = false
    @State private var showsRepairConfirmation = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.08), Color.clear, Color.cyan.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .background(Color(nsColor: .windowBackgroundColor))
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    content
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 42)
                .padding(.vertical, 34)
                .frame(maxWidth: .infinity)
            }
        }
        .alert(item: $model.presentedError) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("好")))
        }
        .confirmationDialog(
            "修复“\(model.report?.displayName ?? "应用")”？",
            isPresented: $showsRepairConfirmation,
            titleVisibility: .visible
        ) {
            Button("移除隔离属性并修复") { model.repair() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将递归移除此应用的下载隔离属性，然后刷新 Launch Services 并重新验证。不会修改应用代码或关闭系统安全功能。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("应用修复")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("快速解决 macOS 应用打开限制与安全验证问题")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .empty:
            dropZone
        case .inspecting:
            progressCard(title: "正在检测应用…", detail: "检查应用结构、签名、架构与 Gatekeeper 状态")
        case .ready, .repairing, .repaired:
            if let report = model.report { reportView(report) }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 18) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 38, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 78, height: 78)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(spacing: 7) {
                Text("拖入需要修复的应用")
                    .font(.system(size: 18, weight: .semibold))
                Text("支持 .app 应用包，也可以从 Finder 中选择")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Button("选择应用…") { model.selectApplication() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 390)
        .padding(34)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.white.opacity(0.22), lineWidth: isDropTargeted ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 24, y: 12)
        .scaleEffect(isDropTargeted ? 1.008 : 1)
        .animation(.easeOut(duration: 0.16), value: isDropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "app" }) else {
                model.presentedError = PresentedError(title: "无法检测", message: "请拖入一个 .app 应用。")
                return false
            }
            model.inspect(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private func reportView(_ report: AppRepairReport) -> some View {
        VStack(spacing: 18) {
            applicationCard(report)
            findingsCard(report)
            actionCard(report)
        }
    }

    private func applicationCard(_ report: AppRepairReport) -> some View {
        HStack(spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: report.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.16), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(report.displayName).font(.title3.weight(.semibold))
                Text([report.version.map { "版本 \($0)" }, report.bundleIdentifier].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(report.url.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("更换应用") { model.reset() }
                .buttonStyle(.borderless)
        }
        .padding(20)
        .glassCard()
    }

    private func findingsCard(_ report: AppRepairReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("检测结果")
                .font(.headline)
                .padding(.bottom, 12)

            ForEach(Array(report.findings.enumerated()), id: \.element.id) { index, finding in
                findingRow(finding)
                if index < report.findings.count - 1 {
                    Divider().padding(.leading, 34)
                }
            }
        }
        .padding(20)
        .glassCard()
    }

    private func findingRow(_ finding: AppRepairFinding) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: finding.kind.symbolName)
                .foregroundStyle(color(for: finding.kind))
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title).font(.system(size: 14, weight: .medium))
                if let detail = finding.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }

    private func actionCard(_ report: AppRepairReport) -> some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().fill(actionColor.opacity(0.13))
                Image(systemName: actionSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(actionColor)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(actionTitle).font(.headline)
                Text(actionDetail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            if model.phase == .repairing {
                ProgressView().controlSize(.small)
            } else if model.phase == .repaired {
                Button("打开应用") { model.openApplication() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("一键修复") { showsRepairConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!report.needsRepair || !report.structureIsValid)
            }
        }
        .padding(20)
        .glassCard()
    }

    private func progressCard(title: String, detail: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .glassCard()
    }

    private var actionTitle: String {
        switch model.phase {
        case .repairing: "正在修复…"
        case .repaired: "修复完成，可以重新打开应用"
        default: model.report?.summary ?? "准备修复"
        }
    }

    private var actionDetail: String {
        switch model.phase {
        case .repairing: "正在移除隔离属性并重新验证应用状态"
        case .repaired:
            if model.report?.gatekeeperAccepted == true { "隔离属性已移除，应用已通过重新验证。" }
            else { "隔离属性已移除。应用签名或来源仍未通过 Gatekeeper，请仅在信任来源时打开。" }
        default:
            if model.report?.needsRepair == true { "移除下载隔离属性，并刷新系统中的应用注册信息。" }
            else { "当前没有可由本工具安全自动修复的项目。" }
        }
    }

    private var actionSymbol: String { model.phase == .repaired ? "checkmark" : "wrench.and.screwdriver" }
    private var actionColor: Color { model.phase == .repaired ? .green : .accentColor }

    private func color(for kind: AppRepairFindingKind) -> Color {
        switch kind {
        case .success: .green
        case .warning: .orange
        case .failure: .red
        case .information: .blue
        }
    }
}

private extension View {
    func glassCard() -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.055), radius: 16, y: 8)
    }
}

#if DEBUG
struct AppRepairView_Previews: PreviewProvider {
    static var previews: some View { AppRepairView().frame(width: 900, height: 760) }
}
#endif
