import MailKit
import MailpipeCore
import OSLog

nonisolated final class MailExtension: NSObject, MEExtension {
    private let logger = Logger(subsystem: "com.mailpipe.app", category: "identity-probe")
    override init() {
        super.init()
        logger.notice("probe_v2 extension_initialized")
    }
    func handlerForMessageActions() -> any MEMessageActionHandler {
        logger.notice("probe_v2 handler_requested")
        return MessageActionHandler()
    }
}

nonisolated final class MessageActionHandler: NSObject, MEMessageActionHandler {
    private let logger = Logger(subsystem: "com.mailpipe.app", category: "identity-probe")
    func decideAction(for message: MEMessage, completionHandler: @escaping (MEMessageActionDecision?) -> Void) {
        var decision: MEMessageActionDecision?
        defer { completionHandler(decision) }
        // Fixed stage names only: no subject, ID, address, body, path or raw error text.
        logger.info("probe_v2 callback_entered")
        guard message.state == .received else { logger.info("probe_v2 state_not_received"); return }
        guard let group = Bundle.main.object(forInfoDictionaryKey: "MailpipeAppGroup") as? String,
              !group.hasPrefix(".") else { logger.error("probe_v2 group_configuration_invalid"); return }
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            logger.error("probe_v2 container_unavailable"); return
        }
        // Production capture is local-only; the host must resolve an authorized account before dispatch.
        do {
            let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
            if let permission = try inbox.permission(), permission.accepts(message.subject) {
                let ids = (message.headers ?? [:]).filter { $0.key.lowercased() == "message-id" }.flatMap(\.value)
                let messageID = ids.count == 1 ? ids[0].trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) : nil
                if let raw = message.rawData {
                    let oversized = raw.count > 65_536
                    try inbox.publish(InboundCapture(permissionID: permission.id, subject: message.subject, messageID: messageID,
                        raw: oversized ? nil : raw, issue: oversized ? "messageTooLarge" : nil))
                } else if try inbox.claimBody(permission: permission, subject: message.subject, messageID: messageID) {
                    try inbox.publish(InboundCapture(permissionID: permission.id, subject: message.subject, messageID: messageID, raw: nil))
                    decision = .invokeAgainWithBody
                } else if messageID == nil {
                    try inbox.publish(InboundCapture(permissionID: permission.id, subject: message.subject, messageID: nil, raw: nil, issue: "missingMessageID"))
                }
            }
        } catch {
            logger.error("capture_failed")
            try? CaptureInbox(directory: root.appendingPathComponent("inbox")).recordIssue((error as? PipelineError)?.rawValue ?? "captureFailed")
        }
        let store = IdentityProbeStore(directory: root.appendingPathComponent("m0-identity"))
        let scope: IdentityProbeScope
        do { scope = try store.scope() }
        catch {
            let e = error as NSError
            if e.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(e.code) {
                logger.info("probe_v2 scope_missing")
            } else if error is DecodingError {
                logger.error("probe_v2 scope_invalid")
            } else { logger.error("probe_v2 scope_read_failed") }
            return
        }
        guard scope.accepts(subject: scope.subject) else { logger.notice("probe_v2 scope_expired"); return }
        logger.notice("probe_v2 active_scope_callback")
        guard scope.accepts(subject: message.subject) else { logger.notice("probe_v2 subject_not_matched"); return }
        logger.notice("probe_v2 subject_matched")
        do {
            try store.capture(subject: message.subject, headers: message.headers ?? [:])
            // Verify publication: capture may return without writing after consent changes.
            let receipt = try store.diagnosedReceipt()
            guard receipt.nonce == scope.nonce else { logger.notice("probe_v2 scope_changed"); return }
            logger.notice("probe_v2 receipt_verified")
            if scope.requestsBody == true {
                if try store.observeBody(subject: message.subject, rawData: message.rawData) {
                    decision = .invokeAgainWithBody
                    logger.notice("probe_v3 body_requested")
                } else {
                    logger.notice("probe_v3 body_observed_or_request_suppressed")
                }
            }
        } catch let failure as ProbeReadFailure {
            logger.error("probe_v2 receipt_verify_failed code=\(failure.rawValue, privacy: .public)")
        } catch { logger.error("probe_v2 capture_failed") }
    }
}
