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
        let original = isReply ? context.originalMessage.flatMap(Self.original) : nil
        return ComposePopoverController(model: model, original: original, isReply: isReply)
    }

    private static func original(_ message: MEMessage) -> OriginalMessage? {
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
        let modelBody = raw.flatMap { try? PlainMailBody.decode($0, fromMailKit: true) }
        guard let identity = ComposeMessageIdentity(messageID: messageID, subject: message.subject, sender: from,
            to: to, cc: cc, displayBody: displayBody, modelBody: modelBody) else { return nil }
        let source: ComposePanelOriginal?
        if let modelBody, let displayBody {
            source = ComposePanelOriginal(messageID: messageID, subject: message.subject, sender: from,
                                          to: to, cc: cc, body: modelBody, displayBody: displayBody)
        } else {
            source = nil
        }
        return OriginalMessage(identity: identity, source: source)
    }
}

private struct OriginalMessage {
    let identity: ComposeMessageIdentity
    let source: ComposePanelOriginal?
}

@MainActor
private final class ComposePopoverController: MEExtensionViewController {
    private let presentationID = UUID()
    private let model: ComposeSuggestionModel
    private let original: OriginalMessage?
    private let isReply: Bool

    init(model: ComposeSuggestionModel, original: OriginalMessage?, isReply: Bool) {
        self.model = model
        self.original = original
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
        model.present(original: original, isReply: isReply, presentationID: presentationID)
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
    enum Screen {
        case loading, editing, message(String)
        case firstDraft(ComposePanelOffer, subject: String, sourceBody: String)
        case preparing
    }
    enum Operation { case lookup, copy, generate, regenerate }

    @Published private(set) var screen = Screen.loading
    @Published private(set) var busy: Operation?
    @Published var body = ""
    @Published private(set) var feedback: String?
    @Published private(set) var suggestion: ComposePanelSuggestion?
    var canCopy: Bool { !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private let sessionID: UUID
    private var currentPresentation: UUID?
    private var original: OriginalMessage?
    private var task: Task<Void, Never>?
    private var exchange: ComposePanelExchange?

    init(sessionID: UUID) {
        self.sessionID = sessionID
        if let group = Bundle(for: ComposeSessionHandler.self).object(forInfoDictionaryKey: "MailpipeAppGroup") as? String,
           !group.hasPrefix("."), let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            exchange = try? ComposePanelExchange(directory: root.appendingPathComponent("compose-panel"))
        }
    }

    func present(original: OriginalMessage?, isReply: Bool, presentationID: UUID) {
        dismiss()
        currentPresentation = presentationID
        self.original = original
        guard isReply else { reset(panelText("Open a reply to see its suggestion.")); return }
        guard original != nil else { reset(panelText("Mail could not identify the original message.")); return }
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
        guard let original, busy == nil else { return }
        guard let exchange else { reset(panelText("Open Mailpipe, then reopen this panel.")); return }
        let previous = suggestion
        let submitted = body
        let action: ComposePanelAction
        switch operation {
        case .lookup: action = .lookup
        case .copy:
            guard previous != nil, canCopy else { return }
            action = .lookup
        case .regenerate:
            guard let previous else { return }
            action = .regenerate(version: previous.version)
        case .generate:
            guard case let .firstDraft(offer, _, _) = screen else { return }
            action = .generate(version: offer.version, original: offer.body == nil ? original.source : nil)
        }
        busy = operation
        feedback = nil
        task = Task {
            defer {
                if !Task.isCancelled { busy = nil; task = nil }
            }
            do {
                let response = try await exchange.send(sessionID: sessionID, identity: original.identity, action: action)
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
                case let .canGenerate(offer):
                    suggestion = nil
                    body = ""
                    if let subject = offer.subject, let sourceBody = offer.body {
                        screen = .firstDraft(offer, subject: subject, sourceBody: sourceBody)
                    } else if let source = original.source {
                        screen = .firstDraft(offer, subject: source.subject, sourceBody: source.body)
                    } else {
                        reset(panelText("Mail could not provide a readable original message."))
                    }
                case .preparing:
                    suggestion = nil
                    body = ""
                    screen = .preparing
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
        if operation == .generate {
            reset(panelText("Could not generate the draft. Reopen the panel to check its status."))
        } else if operation == .regenerate, suggestion != nil {
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
            case let .firstDraft(offer, subject, sourceBody):
                Text(verbatim: panelText("Generate a reply with %@ using the message below.", offer.agentName))
                    .font(.callout)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !subject.isEmpty { Text(verbatim: subject).bold() }
                        Text(verbatim: sourceBody)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    if model.busy == .generate {
                        ProgressView { Text(verbatim: panelText("Generating draft…")) }
                            .controlSize(.small)
                    } else {
                        Button { model.perform(.generate) } label: {
                            Text(verbatim: panelText("Generate Draft"))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy != nil)
                    }
                }
            case .preparing:
                Text(verbatim: panelText("Mailpipe is already preparing a draft for this message."))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    if model.busy != nil { ProgressView().controlSize(.small) }
                    Button { model.perform(.lookup) } label: { Text(verbatim: panelText("Refresh")) }
                        .disabled(model.busy != nil)
                }
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
