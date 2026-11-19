import SwiftUI
import MailpipeCore
import MailBridge

struct IdentityProbeView: View {
    @State private var account = ""
    @State private var mailbox = "INBOX"
    @State private var messageID = ""
    @State private var subject = ""
    @State private var bodyMarker = ""
    @State private var status = L("No test session authorized")
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
            Text(L("M0 synthetic mail diagnostics · version 3")).font(.title2)
            Text(L("For 15 minutes, record only Message-IDs matching the exact subject. The separate body test checks a synthetic marker and byte count. Data stays on this Mac. No model calls or mail changes."))
            HStack {
                Button(L("Authorize 15-minute synthetic capture")) {
                    do { subject = try store().begin().subject; bodyMarker = ""; status = L("Waiting for a new message from Mail") }
                    catch { status = L("Cannot open shared container. Check signing and App Group.") }
                }
                Button(L("Stop capture")) {
                    do { try store().stop(); subject = ""; bodyMarker = ""; messageID = ""; status = L("Capture authorization revoked") }
                    catch { status = L("Revocation failed. Disable the extension in Mail.") }
                }
            }
            Button(L("Authorize 15-minute synthetic body test")) {
                do {
                    let scope = try store().begin(requestsBody: true)
                    subject = scope.subject; bodyMarker = scope.bodyMarker
                    status = L("Deliver a synthetic message with the exact subject and body marker. Each session requests the body only once.")
                } catch { status = L("Could not create a body test session") }
            }
            Text(subject).textSelection(.enabled)
            Text(bodyMarker).textSelection(.enabled)
            Button(L("Read body test receipt")) {
                do {
                    guard let receipt = try store().bodyReceipt() else { status = L("Body test expired or receipt mismatch"); return }
                    status = L("Raw bytes: %1$@, marker: %2$@. Summary and classification unverified.", String(describing: receipt.rawByteCount), String(describing: receipt.markerFound ? L("matched") : L("No match")))
                } catch { status = L("No body receipt available") }
            }
            Button(L("Read extension receipt")) {
                do {
                    messageID = ""
                    let receipt = try store().diagnosedReceipt()
                    guard receipt.messageIDs.count == 1 else { status = L("Callback received with a missing or ambiguous Message-ID"); return }
                    messageID = receipt.messageIDs[0]; status = L("Extension receipt found. Account match still needs verification.")
                } catch let failure as ProbeReadFailure {
                    status = "[\(failure.rawValue)] \(failure.explanation)"
                } catch { status = L("[containerUnavailable] Cannot open shared container") }
            }
            Divider()
            TextField(L("Authorized test account name"), text: $account)
            TextField(L("Mailbox name in this account"), text: $mailbox)
            TextField(L("Synthetic message ID"), text: $messageID)
            Text(L("Search only the specified account and mailbox. Mail may request automation permission. A unique match confirms scope only and grants no write access."))
            Button(querying ? L("Searching…") : L("Authorize this read-only lookup")) {
                do {
                    let query = try IdentityQuery(accountName: account, mailboxName: mailbox, messageID: messageID)
                    querying = true
                    Task { @MainActor in
                        defer { querying = false }
                        do { status = L("Lookup: %1$@ (read only)", String(describing: try AppleMailIdentityProbe.run(query).status)) }
                        catch IdentityQueryError.automation(let code) { status = L("Automation failed: %1$@. No other channel used.", String(describing: code)) }
                        catch { status = L("Lookup failed. No write identity created.") }
                    }
                } catch { status = L("Enter a complete, valid test scope") }
            }.disabled(querying)
            Text(status).textSelection(.enabled)
        }.padding(24).frame(minWidth: 620, minHeight: 440)
    }
}
