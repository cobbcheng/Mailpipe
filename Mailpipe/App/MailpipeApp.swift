import SwiftUI
import AppKit
import HarnessAdapters
import MailpipeCore

@MainActor
final class WorkbenchModel: ObservableObject {
    @Published var installations: [HarnessInstallation] = []
    @Published var reports: [String: String] = [:]
    @Published var busyIDs: Set<String> = []

    func discover() { installations = HarnessDiscovery.find() }
    func inspect(_ installation: HarnessInstallation) {
        guard busyIDs.insert(installation.id).inserted else { return }
        Task {
            defer { busyIDs.remove(installation.id) }
            do {
                let report: CapabilityReport
                switch installation.kind {
                case .deepseek:
                    report = try await DeepSeekHarnessAdapter(executable: installation.executable, dialect: DeepSeekHarnessDialect()).inspect()
                case .codex:
                    report = try await CodexCLIAdapter(executable: installation.executable, dialect: CodexCLIDialect()).inspect()
                }
                reports[installation.id] = "\(report.version) · \(report.supportsHeadlessRun ? "运行参数齐全" : "缺少必要参数") · 真实邮件未验收"
            } catch {
                reports[installation.id] = "检测失败：\((error as? MailpipeError)?.rawValue ?? "operationFailed")"
            }
        }
    }
}

@main
struct MailpipeApp: App {
    @StateObject private var model = WorkbenchModel()
    @StateObject private var pending = PendingModel()
    var body: some Scene {
        WindowGroup("Mailpipe", id: "workbench") {
            PendingWorkbench(model: pending).frame(minWidth: 820, minHeight: 580)
        }
        .defaultSize(width: 820, height: 620)
        Window("新手引导", id: "onboarding") { OnboardingView(model: pending) }
            .defaultSize(width: 720, height: 640)
        WindowGroup("工具诊断", id: "diagnostics") { WorkbenchView(model: model) }
        WindowGroup("M0 身份验证", id: "identity-probe") { IdentityProbeView() }
        MenuBarExtra("Mailpipe", systemImage: "envelope.badge.shield.half.filled") {
            PendingMenu(model: pending)
        }.menuBarExtraStyle(.window)
    }
}

private struct WorkbenchView: View {
    @ObservedObject var model: WorkbenchModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "envelope.badge.shield.half.filled").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mailpipe").font(.largeTitle.bold())
                    Text("Apple Mail 主动回复助手").foregroundStyle(.secondary)
                }
                Spacer()
                Text("M0 工程预览").font(.caption).padding(8).background(.quaternary, in: Capsule())
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("尚未连接真实邮件", systemImage: "lock.shield")
                        .font(.headline)
                    Text("当前可检查本机工具的版本与参数。邮件采集、自动整理与发送尚未接入。")
                    Text("模型及数据去向未知，由 Harness 配置决定。")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            HStack {
                Text("本机 Harness").font(.title2.bold())
                Spacer()
                Button("重新查找", action: model.discover)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.installations.isEmpty {
                        Text("未找到工具。安装 DeepSeek Harness 或 Codex CLI 后重新查找。")
                            .foregroundStyle(.secondary).padding(.vertical)
                    }
                    ForEach(model.installations) { installation in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(installation.kind.displayName).font(.headline)
                                Spacer()
                                Button(model.busyIDs.contains(installation.id) ? "检测中…" : "检查版本与参数") { model.inspect(installation) }
                                    .disabled(model.busyIDs.contains(installation.id))
                            }
                            Text(installation.executable.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(model.reports[installation.id] ?? "未检测 · 不读取登录凭据")
                                .font(.callout)
                        }.padding().background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }.padding(24).onAppear { model.discover() }
    }
}
