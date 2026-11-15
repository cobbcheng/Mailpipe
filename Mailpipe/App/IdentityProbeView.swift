import SwiftUI
import MailpipeCore
import MailBridge

struct IdentityProbeView: View {
    @State private var account = ""
    @State private var mailbox = "INBOX"
    @State private var messageID = ""
    @State private var subject = ""
    @State private var bodyMarker = ""
    @State private var status = "尚未授权测试会话"
    @State private var querying = false

    private func store() throws -> IdentityProbeStore {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "MailpipeAppGroup") as? String,
              !group.hasPrefix("."),
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw IdentityQueryError.invalidScope
        }
        return IdentityProbeStore(directory: root.appendingPathComponent("m0-identity"))
    }
    var body: some View {
        Form {
            Text("M0 合成邮件验证 · 诊断版 3").font(.title2)
            Text("开始后 15 分钟内，扩展仅记录下列精确主题的 Message-ID。正文实验另行授权；只检查合成正文标记与字节数。材料只留本机，不调用模型、不修改邮件。")
            HStack {
                Button("授权 15 分钟合成采集") {
                    do { subject = try store().begin().subject; bodyMarker = ""; status = "等待 Mail 新邮件回调" }
                    catch { status = "无法打开共享容器；请核对签名与 App Group" }
                }
                Button("停止采集") {
                    do { try store().stop(); subject = ""; bodyMarker = ""; messageID = ""; status = "已撤销采集授权" }
                    catch { status = "撤销失败；请在 Mail 中禁用扩展" }
                }
            }
            Button("授权 15 分钟合成正文实验") {
                do {
                    let scope = try store().begin(requestsBody: true)
                    subject = scope.subject; bodyMarker = scope.bodyMarker
                    status = "请用精确主题与正文标记投递合成测试邮件；每会话最多请求一次正文"
                } catch { status = "无法创建正文实验会话" }
            }
            Text(subject).textSelection(.enabled)
            Text(bodyMarker).textSelection(.enabled)
            Button("读取正文实验回执") {
                do {
                    guard let receipt = try store().bodyReceipt() else { status = "正文会话已失效或回执不匹配"; return }
                    status = "原始字节：\(receipt.rawByteCount)，正文标记：\(receipt.markerFound ? "命中" : "未命中")；不代表摘要或分类验收"
                } catch { status = "尚无可读取的正文回执" }
            }
            Button("读取扩展回执") {
                do {
                    messageID = ""
                    let receipt = try store().diagnosedReceipt()
                    guard receipt.messageIDs.count == 1 else { status = "回调已到达，但 Message-ID 缺失或歧义"; return }
                    messageID = receipt.messageIDs[0]; status = "已读到扩展回执；仍须核验账户定位"
                } catch let failure as ProbeReadFailure {
                    status = "[\(failure.rawValue)] \(failure.explanation)"
                } catch { status = "[containerUnavailable] 无法打开共享容器" }
            }
            Divider()
            TextField("授权的测试账户名称", text: $account)
            TextField("该账户内的邮箱名称", text: $mailbox)
            TextField("合成邮件 Message-ID", text: $messageID)
            Text("仅查询指定账户与邮箱；可能出现 Mail 自动化权限弹窗。唯一命中只证明当前范围，不授权写操作。")
            Button(querying ? "正在查询…" : "授权本次只读定位") {
                do {
                    let query = try IdentityQuery(accountName: account, mailboxName: mailbox, messageID: messageID)
                    querying = true
                    Task { @MainActor in
                        defer { querying = false }
                        do { status = "定位结果：\(try AppleMailIdentityProbe.run(query).status)（未执行写入）" }
                        catch IdentityQueryError.automation(let code) { status = "自动化失败：\(code)；未改用其他渠道" }
                        catch { status = "定位失败；不生成写操作身份" }
                    }
                } catch { status = "请填写完整、有效的测试范围" }
            }.disabled(querying)
            Text(status).textSelection(.enabled)
        }.padding(24).frame(minWidth: 620, minHeight: 440)
    }
}
