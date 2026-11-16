import SwiftUI
import AppKit
import HarnessAdapters
import MailpipeCore

@MainActor
final class WorkbenchModel: ObservableObject {
    @Published var installations: [HarnessInstallation] = []
    @Published var reports: [String: String] = [:]
    @Published var busyIDs: Set<String> = []
    @Published var offlineResult = "尚未运行"

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
                reports[installation.id] = "\(report.version) · \(report.supportsSyntheticProbe ? "探测参数齐全" : "缺少必要参数") · 真实邮件未验收"
            } catch {
                reports[installation.id] = "检测失败：\((error as? MailpipeError)?.rawValue ?? "operationFailed")"
            }
        }
    }
    func runOffline() {
        do {
            let responses = try OfflineProbe.run()
            offlineResult = "通过：\(responses.count) 个 Adapter · 账单分类 · 无需行动"
        } catch { offlineResult = "样例校验失败" }
    }
}

@main
struct MailpipeApp: App {
    @StateObject private var model = WorkbenchModel()
    var body: some Scene {
        WindowGroup("Mailpipe", id: "workbench") {
            WorkbenchView(model: model).frame(minWidth: 680, minHeight: 480)
        }
        .defaultSize(width: 820, height: 620)
        WindowGroup("M0 身份验证", id: "identity-probe") { IdentityProbeView() }
        MenuBarExtra("Mailpipe", systemImage: "envelope.badge.shield.half.filled") {
            MenuContent()
        }
    }
}

private struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Mailpipe · M0 工程预览")
        Text("尚未连接邮件")
        Divider()
        Button("打开工作台") {
            openWindow(id: "workbench")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("M0 身份验证") { openWindow(id: "identity-probe"); NSApp.activate(ignoringOtherApps: true) }
        Button("退出 Mailpipe") { NSApp.terminate(nil) }.keyboardShortcut("q")
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
                    Text("Apple Mail 的 AI 整理助手").foregroundStyle(.secondary)
                }
                Spacer()
                Text("M0 工程预览").font(.caption).padding(8).background(.quaternary, in: Capsule())
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("尚未连接真实邮件", systemImage: "lock.shield")
                        .font(.headline)
                    Text("当前可检查本机工具，运行离线合成样例。邮件采集、自动整理与发送尚未接入。")
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
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("离线合成样例").font(.headline)
                    Text(model.offlineResult).font(.callout)
                    Text("不启动 Harness，不消耗模型额度，不访问 Mail。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("运行样例", action: model.runOffline).buttonStyle(.borderedProminent)
            }
        }.padding(24).onAppear { model.discover() }
    }
}
