import MailKit
import MailpipeCore
import OSLog

nonisolated final class MailExtension: NSObject, MEExtension {
    private let logger = Logger(subsystem: "com.mailpipe.app", category: "mail-extension")
    override init() {
        super.init()
        observeExtension(.initialized)
        logger.notice("extension_initialized")
    }
    @MainActor func handler(for session: MEComposeSession) -> any MEComposeSessionHandler {
        ComposeSessionHandler()
    }

    func handlerForMessageActions() -> any MEMessageActionHandler {
        logger.notice("handler_requested")
        observeExtension(.handlerRequested)
        return MessageActionHandler()
    }
}

nonisolated final class MessageActionHandler: NSObject, MEMessageActionHandler {
    private let logger = Logger(subsystem: "com.mailpipe.app", category: "mail-extension")
    var requiredHeaders: [String] { InboundMailFilter.requiredHeaders + ["message-id"] }

    func decideAction(for message: MEMessage, completionHandler: @escaping (MEMessageActionDecision?) -> Void) {
        var decision: MEMessageActionDecision?
        defer { completionHandler(decision) }
        // Fixed stage names only: no subject, ID, address, body, path or raw error text.
        logger.info("callback_entered")
        guard message.state == .received else { logger.notice("state_not_received"); return }
        guard let group = Bundle.main.object(forInfoDictionaryKey: "MailpipeAppGroup") as? String,
              !group.hasPrefix(".") else { logger.error("group_configuration_invalid"); return }
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            logger.error("container_unavailable"); return
        }
        observeExtension(.messageReceived)
        // Production capture is local-only; the host enforces authorization before dispatch.
        do {
            let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
            var bodyObserved = false
            let outcome = try inbox.receiveMailKitMessage(
                subject: message.subject, sender: message.fromAddress.addressString,
                recipients: message.toAddresses.prefix(100).compactMap(\.addressString),
                cc: message.ccAddresses.prefix(100).compactMap(\.addressString),
                headers: message.headers ?? [:],
                rawData: {
                    let raw = message.rawData
                    bodyObserved = raw != nil
                    return raw
                }()
            )
            if outcome == .requestBody {
                decision = .invokeAgainWithBody
                logger.notice("decision_request_body")
            } else if bodyObserved {
                logger.notice("decision_finished_with_body")
            } else {
                logger.notice("decision_finished_without_body")
            }
        } catch {
            logger.error("capture_failed")
            try? CaptureInbox(directory: root.appendingPathComponent("inbox")).recordIssue((error as? PipelineError)?.rawValue ?? "captureFailed")
        }
    }
}

nonisolated private func observeExtension(_ event: ExtensionObservation.Event) {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "MailpipeAppGroup") as? String,
          !group.hasPrefix("."),
          let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
          let inbox = try? CaptureInbox(directory: root.appendingPathComponent("inbox")) else { return }
    try? ExtensionObservation(event: event, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown").write(to: inbox)
}
