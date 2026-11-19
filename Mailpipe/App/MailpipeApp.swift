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

    func connect(_ action: OpenWindowAction, model: PendingModel) {
        present = { action.openMailpipe(for: model) }
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
    @MainActor func openMailpipe(for model: PendingModel) {
        model.showsOnboardingReceipt = false
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
            LaunchStatusIcon(model: pending, appDelegate: appDelegate)
        }.menuBarExtraStyle(.menu)
        Window("Mailpipe", id: "workbench") {
            if pending.onboarding.completed && !pending.showsOnboardingReceipt {
                PendingWorkbench(model: pending).frame(minWidth: 660, minHeight: 380)
            } else {
                OnboardingView(model: pending) { pending.showsOnboardingReceipt = false }
                    .navigationTitle("开始使用 Mailpipe")
                    .onDisappear { pending.showsOnboardingReceipt = false }
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: pending.onboarding.completed ? 700 : 480,
                     height: pending.onboarding.completed ? 420 : 440)
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
    @ObservedObject var model: PendingModel
    let appDelegate: MailpipeAppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image("MenuBarIcon").accessibilityLabel("Mailpipe")
            .onAppear { appDelegate.connect(openWindow, model: model) }
    }
}

private struct WorkbenchCommand: View {
    @ObservedObject var model: PendingModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(model.onboarding.completed ? "打开工作台" : "继续设置 Mailpipe") { openWindow.openMailpipe(for: model) }
            .keyboardShortcut("1", modifiers: .command)
    }
}

private struct InitialSetupSettings: View {
    @ObservedObject var model: PendingModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            Text("完成初始设置后，可在这里更改处理方式和授权。")
            if model.settings.permission != nil || model.settings.suggestionsOnly == true {
                // Older versions could leave an active grant alongside an unfinished setup draft.
                if !model.settings.paused { Button("暂停处理", action: model.togglePause) }
                Button("撤销已有来信处理授权", role: .destructive, action: model.revoke)
            }
            Button("继续设置 Mailpipe") {
                dismiss()
                openWindow.openMailpipe(for: model)
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
                Section("处理方式") {
                    Text(model.settings.paused ? "已暂停，新任务不会派发。" : "正在处理授权范围内的新邮件。")
                    Button(model.settings.paused ? "恢复处理" : "暂停处理", action: model.togglePause)
                    Text("回复备好后保留在菜单栏。打开工作台审阅，再复制到 Mail。")
                        .foregroundStyle(.secondary)
                }
                configurationFooter
            }.formStyle(.grouped).tabItem { Label("通用", systemImage: "gearshape") }
            Form {
                Section("来信处理") {
                    Picker("处理方式", selection: Binding(get: { model.onboarding.isSuggestionsOnly }, set: { model.onboarding.suggestionsOnly = $0; model.saveOnboarding() })) {
                        Text("处理 MailKit 收到的新邮件").tag(false)
                        Text("逐封建议").tag(true)
                    }
                    if !model.onboarding.isSuggestionsOnly {
                        Text("所有账户的新邮件均可交给所选 AI 工具分拣并准备草稿。").foregroundStyle(.secondary)
                        TextField("精确主题限制（可选）", text: $model.onboarding.exactSubject)
                        Button("打开 Mail 扩展设置", action: model.openMailAndExtensionSettings)
                        Toggle("我已在 Mail 中启用扩展", isOn: $model.onboarding.extensionAcknowledged)
                    } else { Text("每封由你粘贴内容，并确认交给哪个工具。无需 Mail 自动化权限。") }
                }
                configurationFooter
            }.formStyle(.grouped).tabItem { Label("来信处理", systemImage: "envelope") }
            Form {
                Section("AI 工具") {
                    Picker("工具", selection: $model.onboarding.executable) {
                        Text("请选择工具").tag("")
                        ForEach(Array(model.installations.enumerated()), id: \.element.id) { index, tool in
                            Text(tool.kind.displayName + (model.installations.count > 1 ? " \(index + 1)" : "")).tag(tool.executable.path)
                        }
                    }.disabled(model.onboardingBusy)
                    Text("内容会交给所选工具配置的模型。连接测试使用固定合成邮件，一次调用，会消耗额度。") .foregroundStyle(.secondary)
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
                configurationFooter
                Section {
                    DisclosureGroup("高级诊断") {
                        Button("重新查找工具", action: model.rediscoverTools)
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
            }.formStyle(.grouped).tabItem { Label("AI 工具", systemImage: "sparkles") }
            Form {
                Section("隐私与数据") {
                    Text("Mailpipe 不设邮件中转服务器。邮件是否离开本机，取决于你选择的工具及其模型配置。")
                    Text("只交付主题与提取后的正文；不向模型交付附件内容。不读取已发送邮件来学习。")
                    Text("复制草稿不会发送邮件。丢弃草稿不会删除来信或改变未来处理策略。")
                    Button("撤销来信处理授权", role: .destructive, action: model.revoke)
                    Text("撤销后不再授权新邮件处理，已有草稿与暂停状态保留。") .foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("隐私与数据", systemImage: "hand.raised") }
        }.frame(width: 660, height: 520)
            .onChange(of: model.onboarding) { _ in model.saveOnboarding() }
    }
    private var selectedToolName: String { model.installations.first { $0.executable.path == model.onboarding.executable }?.kind.displayName ?? "AI 工具" }
    private var configurationFooter: some View {
        Section {
            if let issue = model.onboardingIssue { Text(issue).foregroundStyle(.secondary) }
            Button("保存配置", action: model.applyConfiguration)
                .disabled(model.onboardingBusy || !model.onboardingTestPassed || (!model.onboarding.isSuggestionsOnly && (!model.onboarding.extensionAcknowledged || !model.hasSharedInbox)))
        }
    }
}
