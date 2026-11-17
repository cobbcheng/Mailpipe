import SwiftUI

struct ManualSuggestionView: View {
    @ObservedObject var model: PendingModel
    @Environment(\.dismiss) private var dismiss
    @State private var id = UUID()
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var reviewing = false
    @State private var reviewedRevision: UUID?
    private var executable: String { model.settings.executable ?? "" }
    private var valid: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && subject.utf8.count <= 998 &&
        !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bodyText.utf8.count <= 16_384 && !executable.isEmpty
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(reviewing ? "确认这一封的内容与去向" : "逐封建议").font(.title2)
            Text("仅处理你粘贴的内容，不读取 Mail，不移动、标记或发送邮件。")
            if reviewing {
                ScrollView { VStack(alignment: .leading, spacing: 12) {
                    Text(subject).font(.headline)
                    Text(bodyText).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                TextField("邮件主题", text: $subject)
                Text("邮件正文（纯文本，最多 16 KiB）")
                TextEditor(text: $bodyText).frame(minHeight: 180).accessibilityLabel("邮件正文")
            }
            Text("目标：\(model.toolName)。邮件会到达该工具配置的模型。")
            Text("最多 \(model.settings.level == .l2 ? 2 : 1) 次调用，消耗所选工具额度。不自动重试。")
            if reviewing && reviewedRevision != model.settings.revision { Text("设置已变更，请返回重新预览和确认。") }
            if let issue = model.issue { Text(issue).foregroundStyle(.secondary) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if reviewing {
                    Button("返回修改") { reviewing = false }
                    Button("确认内容与工具，仅提交这一封") {
                        if reviewedRevision == model.settings.revision && model.confirmManual(id: id, subject: subject, body: bodyText, executable: executable) { dismiss() }
                    }.buttonStyle(.borderedProminent).disabled(model.settings.paused || !valid || model.settings.suggestionsOnly != true || reviewedRevision != model.settings.revision)
                } else {
                    Button("预览内容与去向") { reviewedRevision = model.settings.revision; reviewing = true }.buttonStyle(.borderedProminent).disabled(!valid)
                }
            }
        }.padding(24).frame(width: 640, height: 540)
    }
}
