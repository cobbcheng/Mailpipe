import MailKit

/// Xcode Mail Extension entry point. M0 scaffold intentionally has no mailbox side effects.
final class MailExtension: NSObject, MEExtension {
    func handlerForMessageActions() -> any MEMessageActionHandler { MessageActionHandler() }
}

final class MessageActionHandler: NSObject, MEMessageActionHandler {
    func decideAction(for message: MEMessage, completionHandler: @escaping (MEMessageActionDecision?) -> Void) {
        // Signed App Group handoff and user capture consent are not implemented yet.
        // Do not read rawData, request a body, change flags, or invoke a model from this scaffold.
        completionHandler(nil)
    }
}
