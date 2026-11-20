import AppKit
import MailKit
import MailpipeCore
import SwiftUI

@MainActor
final class ComposeSessionHandler: NSObject, MEComposeSessionHandler {
    private var model: ComposeSuggestionModel?

    func mailComposeSessionDidBegin(_ session: MEComposeSession) {}

    func mailComposeSessionDidEnd(_ session: MEComposeSession) {
        model?.dismiss()
        model = nil
    }

    func viewController(for session: MEComposeSession) -> MEExtensionViewController {
        let model = self.model ?? ComposeSuggestionModel(sessionID: session.sessionID)
        self.model = model
        let context = session.composeContext
        let isReply = context.action == .reply || context.action == .replyAll
        let identity = isReply ? context.originalMessage.flatMap(Self.identity) : nil
        return ComposePopoverController(model: model, identity: identity, isReply: isReply)
    }

    private static func identity(_ message: MEMessage) -> ComposeMessageIdentity? {
        let fields = (message.headers ?? [:]).filter { $0.key.lowercased() == "message-id" }
        let raw = message.rawData
        let rawID = raw.flatMap(MailHeaderCodec.messageID(in:))
        let messageID: String?
        if fields.isEmpty {
            messageID = rawID
        } else {
            guard fields.count == 1, let values = fields.first?.value, values.count == 1 else { return nil }
            if let rawID, ComposeMessageIdentity.digest(forMessageID: rawID) != ComposeMessageIdentity.digest(forMessageID: values[0]) {
                return nil
            }
            messageID = values[0]
        }
        let to = message.toAddresses.compactMap(\.addressString)
        let cc = message.ccAddresses.compactMap(\.addressString)
        guard let messageID, let from = message.fromAddress.addressString,
              to.count == message.toAddresses.count, cc.count == message.ccAddresses.count else { return nil }
        let displayBody = raw.flatMap { try? PlainMailBody.displayText($0, fromMailKit: true) }
        return ComposeMessageIdentity(messageID: messageID, subject: message.subject, sender: from,
                                      to: to, cc: cc, displayBody: displayBody)
    }
}

@MainActor
private final class ComposePopoverController: MEExtensionViewController {
    private let presentationID = UUID()
    private let model: ComposeSuggestionModel
    private let identity: ComposeMessageIdentity?
    private let isReply: Bool

    init(model: ComposeSuggestionModel, identity: ComposeMessageIdentity?, isReply: Bool) {
        self.model = model
        self.identity = identity
        self.isReply = isReply
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 380, height: 280)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let hosting = NSHostingController(rootView: ComposeSuggestionView(model: model))
        addChild(hosting)
        view = hosting.view
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        model.present(identity: identity, isReply: isReply, presentationID: presentationID)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        model.dismiss(presentationID: presentationID)
    }
}

private func panelText(_ key: String, _ argument: String? = nil) -> String {
    let format = Bundle(for: ComposeSessionHandler.self).localizedString(forKey: key, value: key, table: nil)
    return argument.map { String(format: format, $0) } ?? format
}

@MainActor
private final class ComposeSuggestionModel: ObservableObject {
    enum Screen { case loading, editing, message(String) }
    enum Operation { case lookup, copy, regenerate }

    @Published private(set) var screen = Screen.loading
    @Published private(set) var busy: Operation?
    @Published var body = ""
    @Published private(set) var feedback: String?
    @Published private(set) var suggestion: ComposePanelSuggestion?
    var canCopy: Bool { !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private let sessionID: UUID
    private var currentPresentation: UUID?
    private var identity: ComposeMessageIdentity?
    private var task: Task<Void, Never>?
    private var exchange: ComposePanelExchange?

    init(sessionID: UUID) {
        self.sessionID = sessionID
        if let group = Bundle(for: ComposeSessionHandler.self).object(forInfoDictionaryKey: "MailpipeAppGroup") as? String,
           !group.hasPrefix("."), let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            exchange = try? ComposePanelExchange(directory: root.appendingPathComponent("compose-panel"))
        }
    }

    func present(identity: ComposeMessageIdentity?, isReply: Bool, presentationID: UUID) {
        dismiss()
        currentPresentation = presentationID
        self.identity = identity
        guard isReply else { reset(panelText("Open a reply to see its suggestion.")); return }
        guard identity != nil else { reset(panelText("Mail could not identify the original message.")); return }
        screen = .loading
        perform(.lookup)
    }

    func dismiss(presentationID: UUID? = nil) {
        // Mail can present the next controller before the previous one disappears.
        if let presentationID, currentPresentation != presentationID { return }
        currentPresentation = nil
        task?.cancel()
        task = nil
        busy = nil
        feedback = nil
    }

    func edited(_ text: String) {
        body = text
        feedback = nil
    }

    func perform(_ operation: Operation) {
        guard let identity, busy == nil else { return }
        guard let exchange else { reset(panelText("Open Mailpipe, then reopen this panel.")); return }
        let previous = suggestion
        let submitted = body
        guard operation == .lookup || previous != nil, operation != .copy || canCopy else { return }
        busy = operation
        feedback = nil
        task = Task {
            defer {
                if !Task.isCancelled { busy = nil; task = nil }
            }
            do {
                let response: ComposePanelResponse
                if operation == .regenerate, let previous {
                    response = try await exchange.send(sessionID: sessionID, identity: identity,
                                                       action: .regenerate(version: previous.version))
                } else {
                    response = try await exchange.send(sessionID: sessionID, identity: identity, action: .lookup)
                }
                try Task.checkCancellation()
                switch response {
                case let .ready(latest):
                    if operation == .copy && previous?.version == latest.version {
                        let board = NSPasteboard.general
                        board.clearContents()
                        feedback = board.setString(submitted, forType: .string)
                            ? panelText("Copied. Paste in your Mail reply.")
                            : panelText("Could not copy. Try again.")
                    } else if operation == .copy {
                        feedback = panelText("The suggestion changed. Review it before copying.")
                    }
                    if previous?.version != latest.version || operation == .regenerate { body = latest.body }
                    suggestion = latest
                    screen = .editing
                case .noDraft:
                    reset(panelText("No reply suggestion is ready for this message."))
                case .unavailable:
                    reset(panelText("Check that Mailpipe is running and mail processing is authorized."))
                case .changed:
                    reset(panelText("The draft changed. Reopen this panel to review it."))
                case .regenerationLimitReached:
                    feedback = panelText("Each message allows three regenerations.")
                case .failed:
                    showFailure(for: operation)
                }
            } catch {
                if !Task.isCancelled { showFailure(for: operation) }
            }
        }
    }

    private func showFailure(for operation: Operation) {
        if operation == .regenerate, suggestion != nil {
            feedback = panelText("Could not regenerate the suggestion. Your text is still here.")
        } else {
            // Retain unsubmitted edits for a successful recheck when the panel reopens.
            screen = .message(panelText("Open Mailpipe, then reopen this panel."))
        }
    }

    private func reset(_ message: String) {
        body = ""
        suggestion = nil
        feedback = nil
        screen = .message(message)
    }
}

private struct ComposeSuggestionView: View {
    @ObservedObject var model: ComposeSuggestionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: panelText("Reply suggestion")).font(.headline)
            switch model.screen {
            case .loading:
                ProgressView { Text(verbatim: panelText("Loading suggestion…")) }
                    .controlSize(.small)
                Spacer(minLength: 0)
            case .message(let message):
                Text(verbatim: message).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            case .editing:
                TextEditor(text: Binding(get: { model.body }, set: model.edited))
                    .font(.body)
                    .accessibilityLabel(Text(verbatim: panelText("Reply suggestion")))
                    .disabled(model.busy != nil)
                if let message = model.feedback {
                    Text(verbatim: message).font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    if let suggestion = model.suggestion {
                        let hint = Text(verbatim: panelText("Use %@ to draft a new reply to the original message.", suggestion.agentName))
                        Button {
                            model.perform(.regenerate)
                        } label: {
                            Text(verbatim: panelText("Regenerate"))
                        }
                        .help(hint)
                        .accessibilityHint(hint)
                    }
                    Spacer()
                    if model.busy != nil { ProgressView().controlSize(.small) }
                    Button { model.perform(.copy) } label: {
                        Text(verbatim: panelText("Copy reply"))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canCopy)
                }
                .disabled(model.busy != nil)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
