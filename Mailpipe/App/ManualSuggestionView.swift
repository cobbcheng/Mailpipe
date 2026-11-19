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
            Text(reviewing ? "把这封来信交给 Agent？" : "粘贴需要回复的来信").font(.title2)
            Text("确认后，Mailpipe 会在这台 Mac 上保存你粘贴的内容。此操作无需读取 Apple Mail。")
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
            Text("Mailpipe 只把这封来信的主题和正文交给你选择的 \(model.toolName)。")
            Text("Agent 会调用 DeepSeek 云端模型起草一次，消耗你的额度。回复由你发送。")
            if reviewing && reviewedRevision != model.settings.revision { Text("设置已变更，请返回重新预览和确认。") }
            if let issue = model.issue { Text(issue).foregroundStyle(.secondary) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if reviewing {
                    Button("返回修改") { reviewing = false }
                    Button("确认并起草回复") {
                        if reviewedRevision == model.settings.revision && model.confirmManual(id: id, subject: subject, body: bodyText, executable: executable) { dismiss() }
                    }.buttonStyle(.borderedProminent).disabled(model.settings.paused || !valid || model.settings.suggestionsOnly != true || reviewedRevision != model.settings.revision)
                } else {
                    Button("核对来信与 Agent") { reviewedRevision = model.settings.revision; reviewing = true }.buttonStyle(.borderedProminent).disabled(!valid)
                }
            }
        }.padding(24).frame(width: 640, height: 540)
    }
}
