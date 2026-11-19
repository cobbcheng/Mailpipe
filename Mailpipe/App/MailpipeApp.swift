import SwiftUI
import AppKit
import HarnessAdapters
import MailBridge
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
                reports[installation.id] = "\(report.version) · \(report.supportsHeadlessRun ? "运行参数齐全" : "缺少必要参数")"
            } catch {
                reports[installation.id] = "检测失败：\((error as? MailpipeError)?.rawValue ?? "operationFailed")"
            }
        }
    }
}

@main
enum MailpipeEntryPoint {
    @MainActor static func main() {
        if MailReadBridge.runHelperIfRequested() { return }
        // LSUIElement keeps every read helper out of the Dock from launch.
        // Only the interactive host presents a regular application.
        NSApplication.shared.setActivationPolicy(.regular)
        MailpipeApp.main()
    }
}

@MainActor
private final class MailpipeAppDelegate: NSObject, NSApplicationDelegate {
    private var present: (() -> Void)?
    private var awaitingWindow = false

    func connect(_ action: OpenWindowAction) {
        present = { action.openMailpipe() }
        if awaitingWindow {
            awaitingWindow = false
            present?()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        guard event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) == nil,
              event?.paramDescriptor(forKeyword: keyAELaunchedAsServiceItem) == nil else { return }
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    private func showMainWindow() {
        // AppKit can deliver the event before the menu bar label supplies SwiftUI's window action.
        if let present { present() }
        else { awaitingWindow = true }
    }
}

extension OpenWindowAction {
    @MainActor func openMailpipe() {
        self(id: "workbench")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MailpipeApp: App {
    @NSApplicationDelegateAdaptor(MailpipeAppDelegate.self) private var appDelegate
    @StateObject private var model = WorkbenchModel()
    @StateObject private var pending = PendingModel()
    var body: some Scene {
        MenuBarExtra {
            PendingMenu(model: pending)
        } label: {
            LaunchStatusIcon(appDelegate: appDelegate)
        }.menuBarExtraStyle(.menu)
        Window("Mailpipe", id: "workbench") {
            if pending.onboarding.completed {
                PendingWorkbench(model: pending).frame(minWidth: 660, minHeight: 380)
            } else {
                OnboardingView(model: pending)
                    .navigationTitle("开始使用 Mailpipe")
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: pending.onboarding.completed ? 900 : 480,
                     height: pending.onboarding.completed ? 580 : 440)
        .commands {
            CommandGroup(after: .newItem) {
                WorkbenchCommand(model: pending)
            }
        }
        Settings {
            if pending.onboarding.completed {
                MailpipeSettings(model: pending, diagnostics: model)
            } else {
                InitialSetupSettings(model: pending)
            }
        }
    }
}

private struct LaunchStatusIcon: View {
    let appDelegate: MailpipeAppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image("MenuBarIcon").accessibilityLabel("Mailpipe")
            .onAppear { appDelegate.connect(openWindow) }
    }
}

private struct WorkbenchCommand: View {
    @ObservedObject var model: PendingModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(model.onboarding.completed ? "打开工作台" : "继续设置 Mailpipe") { openWindow.openMailpipe() }
            .keyboardShortcut("1", modifiers: .command)
    }
}

private struct InitialSetupSettings: View {
    @ObservedObject var model: PendingModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            Text("先连接你的 Agent，再选择要交给它起草回复的来信。")
            if model.settings.permission != nil {
                // Older versions could leave an active grant alongside an unfinished setup draft.
                if !model.settings.paused { Button("暂停处理", action: model.togglePause) }
                Button("撤销已有来信处理授权", role: .destructive, action: model.revoke)
            }
            Button("继续设置 Mailpipe") {
                dismiss()
                openWindow.openMailpipe()
            }.keyboardShortcut(.defaultAction)
        }.padding(32)
    }
}

struct MailpipeSettings: View {
    @ObservedObject var model: PendingModel
    @ObservedObject var diagnostics: WorkbenchModel
    var body: some View {
        TabView {
            Form {
                Section("回复草稿") {
                    Text(model.settings.paused ? "已暂停向 Agent 提交来信。" : "Agent 只能为你授权的来信起草回复。")
                    Button(model.settings.paused ? "恢复处理" : "暂停处理", action: model.togglePause)
                    Text("草稿保存在这台 Mac 上。从菜单栏打开工作台，改好回复后由你在 Apple Mail 发送。")
                        .foregroundStyle(.secondary)
                }
                configurationFooter()
            }.formStyle(.grouped).tabItem { Label("通用", systemImage: "gearshape") }
            Form {
                Section("来信处理") {
                    Text("授权后，\(selectedToolName) 会用 Apple Mail 所有账户的新来信主题和正文起草回复。填写主题后，仅处理主题完全匹配的新来信。").foregroundStyle(.secondary)
                    TextField("限定邮件主题（可选）", text: $model.onboarding.exactSubject)
                    Button("打开 Mail 扩展设置", action: model.openMailAndExtensionSettings)
                    Toggle("我已在 Mail 中启用扩展", isOn: $model.onboarding.extensionAcknowledged)
                }
                configurationFooter(confirmsScope: true)
            }.formStyle(.grouped).tabItem { Label("来信处理", systemImage: "envelope") }
            Form {
                Section("起草回复的 Agent") {
                    Picker("Agent", selection: $model.onboarding.executable) {
                        Text("选择 Agent").tag("")
                        ForEach(Array(model.installations.enumerated()), id: \.element.id) { index, tool in
                            Text(tool.kind.displayName + (model.installations.count > 1 ? " \(index + 1)" : "")).tag(tool.executable.path)
                        }
                    }.disabled(model.onboardingBusy)
                    Text("连接测试使用一封示例邮件，让 Agent 调用一次 DeepSeek 云端模型，会消耗额度。").foregroundStyle(.secondary)
                    if model.onboardingBusy {
                        ProgressView("正在连接…")
                        Button("取消测试", action: model.cancelOnboardingTest)
                    } else if model.onboardingTestPassed {
                        Label("已连接到 \(selectedToolName)", systemImage: "checkmark.circle")
                        Button("重新测试") { model.resetOnboardingTest(); model.testOnboarding() }
                    } else {
                        Button("确认并测试连接") { model.resetOnboardingTest(); model.testOnboarding() }.disabled(model.onboarding.executable.isEmpty)
                    }
                }
                configurationFooter()
                Section {
                    DisclosureGroup("高级诊断") {
                        Button("重新查找 Agent", action: model.rediscoverTools)
                        ForEach(model.installations) { tool in
                            Text(tool.executable.path).textSelection(.enabled)
                            Button("检查版本与参数") { diagnostics.inspect(tool) }.disabled(diagnostics.busyIDs.contains(tool.id))
                            if let report = diagnostics.reports[tool.id] { Text(report) }
                        }
                        if let issue = model.issue { Text(issue).textSelection(.enabled) }
                        if let result = model.onboardingResult {
                            ForEach(result.runs, id: \.destination.runID) { run in
                                Text("输入 token：\(run.inputTokens.map(String.init) ?? "未知")；输出 token：\(run.outputTokens.map(String.init) ?? "未知")")
                                Text("输入字符：\(run.inputCharacters.map(String.init) ?? "未知")；输出字符：\(run.outputCharacters.map(String.init) ?? "未知")；实付金额：未知")
                            }
                        }
                    }
                }
            }.formStyle(.grouped).tabItem { Label("Agent", systemImage: "sparkles") }
            Form {
                Section("隐私与数据") {
                    Text("Mailpipe 在这台 Mac 上保存来信、草稿和设置，只把获准起草的邮件主题和正文交给你连接的 Agent。")
                    Text("DeepSeek Harness 会把这些内容发给 DeepSeek 云端模型。邮件不经 Mailpipe 服务器中转，附件内容也不会交给模型。")
                    Text("来信含 GitHub PR 链接时，Agent 可核对公开变更。使用你的 GitHub 账户读取变更，需要你另行确认。")
                    Button("撤销来信处理授权", role: .destructive, action: model.revoke)
                    Text("撤销后，Agent 不再处理新来信。已有草稿仍可在本机查看。").foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("隐私与数据", systemImage: "hand.raised") }
        }.frame(width: 660, height: 520)
            .onChange(of: model.onboarding) { _ in model.saveOnboarding() }
    }
    private var selectedToolName: String { model.installations.first { $0.executable.path == model.onboarding.executable }?.kind.displayName ?? "所选 Agent" }
    private func configurationFooter(confirmsScope: Bool = false) -> some View {
        Section {
            if let issue = model.onboardingIssue { Text(issue).foregroundStyle(.secondary) }
            if confirmsScope || !model.needsPermissionRecovery {
                Button(model.needsPermissionRecovery ? "授权 Agent 处理新来信" : "保存配置", action: model.applyConfiguration)
                    .disabled(model.onboardingBusy || !model.onboardingTestPassed || !model.onboarding.extensionAcknowledged || !model.hasSharedInbox)
            }
        }
    }
}
