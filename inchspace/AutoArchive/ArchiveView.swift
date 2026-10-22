import SwiftUI

/// Auto-archive in one screen: a short first-run guide, then a single glass status card.
struct ArchiveView: View {
    @ObservedObject var model: ArchiveViewModel
    @ObservedObject var aiSettings: TerminalAISettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ArchiveBackdrop()
            switch model.screen {
            case .loading:
                ArchiveLoadingView(model: model)
            case .onboarding:
                ArchiveOnboardingView(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .dashboard:
                ArchiveDashboardView(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(reduceMotion ? nil : AppMotion.transition, value: model.screen)
        .task {
            model.attach(settings: aiSettings)
            await model.bootstrap()
        }
        .sheet(isPresented: $model.showDetails) { ArchiveDetailsSheet(model: model) }
    }
}

private struct ArchiveBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            // Glass needs something to refract; two soft color fields are enough.
            RadialGradient(colors: [Color.accentColor.opacity(0.28), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color.teal.opacity(0.18), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 560)
        }
        .ignoresSafeArea()
    }
}

private struct ArchiveLoadingView: View {
    @ObservedObject var model: ArchiveViewModel

    var body: some View {
        VStack(spacing: 14) {
            if let error = model.loadError {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(.orange)
                Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("重新载入") { Task { await model.bootstrap() } }.buttonStyle(.glass)
            } else {
                ProgressView()
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
    }
}

// MARK: - First-run guide

private struct ArchiveOnboardingView: View {
    @ObservedObject var model: ArchiveViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassCard {
            VStack(spacing: 22) {
                switch model.onboardingStep {
                case .welcome: welcome
                case .folder: folder
                case .privacy: privacy
                }
                StepDots(current: model.onboardingStep.rawValue, count: ArchiveOnboardingStep.allCases.count)
            }
            .id(model.onboardingStep)
            .transition(.opacity)
        }
        .animation(reduceMotion ? nil : AppMotion.transition, value: model.onboardingStep)
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            CardHeader(symbol: "sparkles.rectangle.stack", title: "让文件夹自己变整齐",
                       subtitle: "选一个文件夹，其余的交给寸空间。")
            Button { model.advanceOnboarding() } label: { Text("开始").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent).controlSize(.large)
        }
    }

    private var folder: some View {
        VStack(spacing: 22) {
            CardHeader(symbol: "folder.badge.plus", title: "选择要整理的文件夹",
                       subtitle: "比如“下载”或“文档”。文件只会在这个文件夹内部移动。")
            Button { model.chooseFolder() } label: { Text("选择文件夹…").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent).controlSize(.large)
            if case .failed(let message) = model.activity {
                Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
    }

    private var privacy: some View {
        VStack(spacing: 22) {
            CardHeader(symbol: "lock.shield", title: "要用 AI 来整理吗？",
                       subtitle: "AI 只会收到文件名和少量关键词，不会收到文件正文。不用 AI 时，会在本机按文件类型整理。")
            if let folder = model.workspace {
                Label(folder.url.lastPathComponent, systemImage: "folder")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(spacing: 10) {
                if model.isModelConfigured {
                    Button { model.finishOnboarding(useAI: true) } label: { Text("同意并使用 AI").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent).controlSize(.large)
                    Button { model.finishOnboarding(useAI: false) } label: { Text("仅在本机整理").frame(maxWidth: .infinity) }
                        .buttonStyle(.glass).controlSize(.large)
                } else {
                    Button { model.finishOnboarding(useAI: false) } label: { Text("在本机整理").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent).controlSize(.large)
                    Button { model.openModelSettings() } label: { Text("先配置 AI 模型").frame(maxWidth: .infinity) }
                        .buttonStyle(.glass).controlSize(.large)
                }
            }
        }
    }
}

// MARK: - Status card

private struct ArchiveDashboardView: View {
    @ObservedObject var model: ArchiveViewModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GlassCard {
                VStack(spacing: 22) {
                    status
                    actions
                }
            }
            Button { model.showDetails = true } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("更多")
                .padding(20)
        }
        .frame(maxWidth: 480)
    }

    @ViewBuilder private var status: some View {
        switch model.activity {
        case .working(let message):
            VStack(spacing: 16) {
                StatusOrb { ProgressView().controlSize(.large) }
                Text(message).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    .contentTransition(.numericText())
                ArchiveRunProgressBar(progress: model.progress, detail: model.progressDetail, startedAt: model.runStartedAt)
                Text(folderLine).font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(spacing: 16) {
                StatusOrb { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 26)).foregroundStyle(.orange) }
                Text("暂时没能整理").font(.title3.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        case .idle:
            VStack(spacing: 16) {
                StatusOrb { Image(systemName: "checkmark").font(.system(size: 26, weight: .semibold)).foregroundStyle(.green) }
                Text(idleTitle).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Text(folderLine).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var idleTitle: String {
        if let summary = model.lastSummary, !summary.isEmpty { return "刚刚整理了 \(summary.movedFiles) 个文件" }
        return "文件夹很整齐"
    }

    private var folderLine: String {
        let name = model.workspace?.url.lastPathComponent ?? ""
        let how = model.usesAI ? "AI 整理" : "本机整理"
        return model.isWatching ? "\(name) · \(how)中" : "\(name) · 已暂停"
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                switch model.activity {
                case .working:
                    Button("停止") { model.cancelRun() }.buttonStyle(.glass)
                case .failed:
                    Button("重试") { model.dismissFailure(); model.organize() }.buttonStyle(.glassProminent)
                    Button("模型设置") { model.openModelSettings() }.buttonStyle(.glass)
                case .idle:
                    Button("立即整理") { model.organize() }.buttonStyle(.glassProminent)
                    if let batch = model.batches.first {
                        Button("撤销本次") { Task { await model.undo(batch) } }.buttonStyle(.glass)
                    }
                    Button(model.isWatching ? "暂停" : "恢复") { model.setWatching(!model.isWatching) }.buttonStyle(.glass)
                }
            }
            .controlSize(.large)
        }
    }
}

// MARK: - Secondary details

private struct ArchiveDetailsSheet: View {
    @ObservedObject var model: ArchiveViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("整理记录").font(.title3.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(.glassProminent)
            }
            .padding(20)
            if model.batches.isEmpty {
                ContentUnavailableView("还没有整理记录", systemImage: "tray")
                    .frame(maxHeight: .infinity)
            } else {
                List(model.batches) { plan in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(plan.createdAt.formatted(.relative(presentation: .named)))").font(.body.weight(.medium))
                            Text(detail(plan)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("撤销") { Task { await model.undo(plan) } }
                            .buttonStyle(.glass)
                            .disabled(model.isRunning)
                    }
                    .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
            }
            Divider()
            HStack(spacing: 10) {
                if let folder = model.workspace {
                    Button("在访达中显示", systemImage: "folder") { model.reveal(folder.url) }
                }
                Button("更换文件夹", systemImage: "arrow.triangle.2.circlepath") { model.chooseFolder() }
                Button("重新整理全部", systemImage: "arrow.clockwise") {
                    dismiss()
                    Task { await model.reorganizeEverything() }
                }
                .disabled(model.isRunning)
                Spacer()
                Button(model.usesAI ? "改用本机整理" : "使用 AI 整理", systemImage: model.usesAI ? "desktopcomputer" : "sparkles") {
                    model.setAI(!model.usesAI)
                }
                Button("模型设置", systemImage: "cpu") { dismiss(); model.openModelSettings() }
            }
            .buttonStyle(.glass)
            .labelStyle(.titleAndIcon)
            .padding(16)
        }
        .frame(width: 680, height: 520)
        .background(.ultraThinMaterial)
    }

    private func detail(_ plan: ArchiveAIPlan) -> String {
        let moved = plan.files.filter { $0.status == .complete }.count
        let created = plan.directories.filter { $0.action == .create && $0.status == .complete }.count
        return created == 0 ? "移动了 \(moved) 个文件" : "移动了 \(moved) 个文件，新建 \(created) 个文件夹"
    }
}

// MARK: - Shared glass pieces

/// Determinate once the folder size is known, indeterminate before; always shows elapsed time so a
/// long model call never looks frozen.
private struct ArchiveRunProgressBar: View {
    let progress: ArchiveRunProgress?
    let detail: String?
    let startedAt: Date?

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let fraction = progress?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView(value: nil as Double?)
                }
            }
            .progressViewStyle(.linear)
            .tint(Color.accentColor)
            .animation(.easeInOut(duration: 0.4), value: progress?.fraction)
            HStack(spacing: 6) {
                if let detail {
                    Text(detail).contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                if let startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(elapsed(from: startedAt, to: context.date)).monospacedDigit()
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: 360)
        .accessibilityElement(children: .combine)
    }

    private func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 3_600 ? String(format: "%d:%02d", seconds / 60, seconds % 60)
            : String(format: "%d:%02d:%02d", seconds / 3_600, seconds % 3_600 / 60, seconds % 60)
    }
}

private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(32)
            .frame(maxWidth: 480)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .padding(24)
    }
}

private struct CardHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            StatusOrb {
                Image(systemName: symbol).font(.system(size: 26, weight: .medium))
                    .symbolRenderingMode(.hierarchical).foregroundStyle(Color.accentColor)
            }
            Text(title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StatusOrb<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: 64, height: 64)
            .glassEffect(.regular, in: .circle)
            .accessibilityHidden(true)
    }
}

private struct StepDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: index == current ? 18 : 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(current + 1) 步，共 \(count) 步")
    }
}
