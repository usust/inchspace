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
        VStack(spacing: 0) {
            header
            ScrollView {
                content
                    .frame(maxWidth: AppLayout.contentMaxWidth, alignment: .leading)
                    .padding(AppLayout.pagePadding)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(item: $model.presentedError) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("好")))
        }
        .confirmationDialog(
            "移除“\(model.report?.displayName ?? "应用")”的隔离属性？",
            isPresented: $showsRepairConfirmation,
            titleVisibility: .visible
        ) {
            Button("移除下载隔离属性") { model.repair() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅对来源可信的应用使用。将递归移除下载隔离属性，刷新 Launch Services 并重新验证；这可能绕过下载隔离触发的安全检查，但不会修复签名、清除系统拦截提示或授予本地网络等隐私权限。不会重签名或关闭系统安全功能；必要时请求管理员授权。")
        }
    }

    private var header: some View {
        AppFeatureTitle("应用修复")
            .frame(maxWidth: .infinity, alignment: .leading)
            .appFeatureHeaderBackground()
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
        VStack(spacing: 16) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 32, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)

            Text("拖入 .app 应用")
                .font(.headline)

            Button("选择应用…") { model.selectApplication() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(AppLayout.pagePadding)
        .appSurface()
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        }
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
        VStack(spacing: AppLayout.sectionSpacing) {
            applicationCard(report)
            findingsCard(report)
            actionCard(report)
            privacyGuidance
        }
    }

    private func applicationCard(_ report: AppRepairReport) -> some View {
        HStack(spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: report.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)

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
                .disabled(model.phase == .repairing)
        }
        .padding(20)
        .appSurface()
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
        .appSurface()
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
                Button("移除隔离属性") { showsRepairConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!report.needsRepair || !report.structureIsValid)
            }
        }
        .padding(20)
        .appSurface()
    }

    private var privacyGuidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("安全放行与隐私授权是两回事", systemImage: "hand.raised")
                .font(.headline)
            Text("移除下载隔离属性不会授予本地网络、辅助功能或屏幕录制权限，也不保证系统设置中的“已阻止”提示消失。签名完整性检查通过，也不等于应用来自已验证的开发者。")
            Text("若应用仍被阻止，优先从开发者官方渠道获取已签名并公证的版本。仅在确认来源可信后，才考虑在系统设置 → 隐私与安全性中使用“仍要打开”。")
            Text("若无法访问本地网络，请在系统设置 → 隐私与安全性 → 本地网络中检查该应用的开关。若没有条目，重新打开应用并实际触发局域网访问；仍无提示或连接失败时，需要进一步检查应用本身。不要通过强制重签名或清空所有隐私授权来处理。")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .appSurface()
    }

    private func progressCard(title: String, detail: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(title).font(.headline).help(detail)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .appSurface()
    }

    private var actionTitle: String {
        switch model.phase {
        case .repairing: "正在移除隔离属性…"
        case .repaired: model.report?.removalResultTitle ?? "隔离属性处理结束"
        default: model.report?.summary ?? "准备修复"
        }
    }

    private var actionDetail: String {
        switch model.phase {
        case .repairing: "正在移除隔离属性并重新验证应用状态"
        case .repaired:
            model.report?.removalResultDetail ?? "请重新检测应用状态。"
        default:
            if model.report?.needsRepair == true { "移除下载隔离属性，并刷新系统中的应用注册信息。" }
            else { "当前没有可由本工具安全自动修复的项目。" }
        }
    }

    private var actionSymbol: String {
        guard model.phase == .repaired else { return "wrench.and.screwdriver" }
        return (model.report?.removalResultKind ?? .warning).symbolName
    }

    private var actionColor: Color {
        guard model.phase == .repaired else { return .accentColor }
        return color(for: model.report?.removalResultKind ?? .warning)
    }

    private func color(for kind: AppRepairFindingKind) -> Color {
        switch kind {
        case .success: .green
        case .warning: .orange
        case .failure: .red
        case .information: .blue
        }
    }
}

#if DEBUG
struct AppRepairView_Previews: PreviewProvider {
    static var previews: some View { AppRepairView().frame(width: 900, height: 760) }
}
#endif
