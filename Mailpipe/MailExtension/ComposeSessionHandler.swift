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
        let model = self.model.flatMap { $0.sessionID == session.sessionID ? $0 : nil } ?? ComposeSuggestionModel(sessionID: session.sessionID)
        self.model = model
        let context = session.composeContext
        let isReply = context.action == .reply || context.action == .replyAll
        let supportsSuggestions = isReply || context.action == .forward
        let projected = context.originalMessage
        let original = supportsSuggestions ? projected.flatMap {
            OriginalMessage($0, reply: isReply ? session.mailMessage : nil)
        } : nil
        let hint = original?.messageID == nil ? subjectHint(for: session.mailMessage) : nil
        return ComposePopoverController(model: model, original: original, subjectHint: hint)
    }
}

// A subject can narrow a user-requested search, but cannot identify a message.
private func forwardedSubjectDigest(_ subject: String) -> String? {
    guard let colon = subject.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
    let prefix = subject[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
    guard ["fw", "fwd", "转发", "轉發", "转寄", "轉寄", "rv", "reenv", "reenviado"].contains(prefix) else { return nil }
    let original = subject[subject.index(after: colon)...].drop(while: \.isWhitespace)
    guard !original.isEmpty, original.utf8.count <= 2048 else { return nil }
    return ComposeMessageIdentity.digest(forSubject: String(original))
}

private func exactSubjectDigest(_ subject: String) -> String? {
    let text = subject.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.utf8.count <= 2048 else { return nil }
    return forwardedSubjectDigest(text) ?? ComposeMessageIdentity.digest(forSubject: text)
}

private func subjectHint(for outgoing: MEMessage) -> String? {
    let subject = MailHeaderCodec.decodeEncodedWords(outgoing.subject)
    if let digest = forwardedSubjectDigest(subject) { return digest }
    let fields = (outgoing.headers ?? [:]).filter { $0.key.lowercased() == "subject" }
    guard fields.count == 1, let values = fields.first?.value, values.count == 1 else { return exactSubjectDigest(subject) }
    let header = MailHeaderCodec.decodeEncodedWords(values[0])
    return forwardedSubjectDigest(header) ?? exactSubjectDigest(subject) ?? exactSubjectDigest(header)
}

@MainActor
private struct OriginalMessage {
    let message: MEMessage
    let sender: String
    let to: [String]
    let cc: [String]
    private(set) var messageID: String?

    init?(_ message: MEMessage, reply: MEMessage?) {
        // Only a reply's outgoing In-Reply-To identifies the original. A forward uses the forwarded message itself.
        let originalID = (message.headers ?? [:]).filter { $0.key.lowercased() == "message-id" }
        let parentID = (reply?.headers ?? [:]).filter { $0.key.lowercased() == "in-reply-to" }
        var id: String?
        for fields in [originalID, parentID] where !fields.isEmpty {
            guard fields.count == 1, let values = fields.first?.value, values.count == 1,
                  let digest = ComposeMessageIdentity.digest(forMessageID: values[0]) else { return nil }
            if let id, ComposeMessageIdentity.digest(forMessageID: id) != digest { return nil }
            id = values[0]
        }
        guard let sender = message.fromAddress.addressString else { return nil }
        let to = message.toAddresses.compactMap(\.addressString)
        let cc = message.ccAddresses.compactMap(\.addressString)
        guard to.count == message.toAddresses.count, cc.count == message.ccAddresses.count else { return nil }
        self.message = message
        self.messageID = id
        self.sender = sender
        self.to = to
        self.cc = cc
    }

    func identity(displayBody: String? = nil, modelBody: String? = nil) -> ComposeMessageIdentity? {
        guard let messageID else { return nil }
        return ComposeMessageIdentity(messageID: messageID, subject: message.subject, sender: sender,
                                      to: to, cc: cc, displayBody: displayBody, modelBody: modelBody)
    }

    mutating func recoverMessageID() {
        messageID = message.rawData.flatMap(MailHeaderCodec.messageID(in:))
    }

    // MailKit provides one raw message accessor. Read it only for a requested draft or a ready-draft identity check.
    func evidence(requiresSource: Bool) throws -> (identity: ComposeMessageIdentity, source: ComposePanelOriginal?) {
        guard let messageID else { throw ComposePanelTransportError.invalidRequest }
        let raw = message.rawData
        if let rawID = raw.flatMap(MailHeaderCodec.messageID(in:)),
           ComposeMessageIdentity.digest(forMessageID: rawID) != ComposeMessageIdentity.digest(forMessageID: messageID) {
            throw ComposePanelTransportError.invalidRequest
        }
        let displayBody = raw.flatMap { try? PlainMailBody.displayText($0, fromMailKit: true) }
        let modelBody = requiresSource ? raw.flatMap { try? PlainMailBody.decode($0, fromMailKit: true) } : nil
        guard let identity = identity(displayBody: displayBody, modelBody: modelBody) else { throw ComposePanelTransportError.invalidRequest }
        guard requiresSource else { return (identity, nil) }
        guard let displayBody, let modelBody, let source = ComposePanelOriginal(messageID: messageID, subject: message.subject,
            sender: sender, to: to, cc: cc, body: modelBody, displayBody: displayBody) else { throw ComposePanelTransportError.invalidRequest }
        return (identity, source)
    }
}

@MainActor
private final class ComposePopoverController: MEExtensionViewController {
    private let presentationID = UUID()
    private let model: ComposeSuggestionModel
    private let original: OriginalMessage?
    private let subjectHint: String?

    init(model: ComposeSuggestionModel, original: OriginalMessage?, subjectHint: String?) {
        self.model = model
        self.original = original
        self.subjectHint = subjectHint
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
        model.present(original: original, subjectHint: subjectHint, presentationID: presentationID)
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
        case firstDraft(ComposePanelOffer)
        case missingMessageID
        case chooseDraft, searchSubject(emptyResult: Bool), draftChoices([ComposeDraftChoice])
        case preparing
    }
    enum Operation { case lookup, findDrafts, copy, generate, regenerate }

    @Published private(set) var screen = Screen.loading
    @Published private(set) var busy: Operation?
    @Published var body = ""
    @Published var searchText = ""
    @Published private(set) var feedback: String?
    @Published private(set) var suggestion: ComposePanelSuggestion?
    var canCopy: Bool { !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canChangeChoice: Bool { selectedIdentity != nil }
    var hasSubjectHint: Bool { searchDigest != nil }
    var canSearch: Bool { exactSubjectDigest(searchText) != nil }
    let sessionID: UUID
    private var currentPresentation: UUID?
    private var original: OriginalMessage?
    private var projectedHint: String?
    private var searchDigest: String?
    private var selectedIdentity: ComposeMessageIdentity?
    private var task: Task<Void, Never>?
    private var exchange: ComposePanelExchange?

    init(sessionID: UUID) {
        self.sessionID = sessionID
        if let group = Bundle(for: ComposeSessionHandler.self).object(forInfoDictionaryKey: "MailpipeAppGroup") as? String,
           !group.hasPrefix("."), let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            exchange = try? ComposePanelExchange(directory: root.appendingPathComponent("compose-panel"))
        }
    }

    func present(original: OriginalMessage?, subjectHint: String?, presentationID: UUID) {
        dismiss()
        currentPresentation = presentationID
        self.original = original
        if original?.messageID != nil {
            if searchDigest != nil { clearSelection() }
            projectedHint = nil
            searchDigest = nil
            searchText = ""
            perform(.lookup)
            return
        }
        if let subjectHint, subjectHint != projectedHint {
            clearSelection()
            projectedHint = subjectHint
            searchDigest = subjectHint
            searchText = ""
        }
        if selectedIdentity != nil {
            self.original = nil
            perform(.lookup)
        } else {
            screen = original == nil ? .chooseDraft : .missingMessageID
        }
    }

    func beginChoosing() {
        guard busy == nil else { return }
        original = nil
        if searchDigest == nil { screen = .searchSubject(emptyResult: false) }
        else { perform(.findDrafts) }
    }

    func search() {
        guard case .searchSubject = screen, let digest = exactSubjectDigest(searchText), busy == nil else { return }
        if digest != searchDigest { clearSelection() }
        searchDigest = digest
        perform(.findDrafts)
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

    func findDraft() {
        guard var original, busy == nil else { return }
        original.recoverMessageID()
        guard original.messageID != nil else { self.original = nil; screen = .chooseDraft; return }
        self.original = original
        screen = .loading
        perform(.lookup)
    }

    func edited(_ text: String) {
        body = text
        feedback = nil
    }

    func choose(_ choice: ComposeDraftChoice) {
        guard busy == nil, case let .draftChoices(choices) = screen, choices.contains(choice),
              choice.identity.subjectDigest == searchDigest, choice.identity.displayBodyDigest != nil else { return }
        if selectedIdentity != choice.identity { clearSelection() }
        selectedIdentity = choice.identity
        screen = .loading
        perform(.lookup)
    }

    func perform(_ operation: Operation) {
        guard busy == nil, currentPresentation != nil else { return }
        guard let exchange else { reset(panelText("Open Mailpipe, then reopen this panel.")); return }
        let original = self.original
        let previous = suggestion
        let submitted = body
        var identity = selectedIdentity ?? original?.identity()
        let action: ComposePanelAction
        switch operation {
        case .findDrafts:
            guard let searchDigest else { return }
            identity = nil
            action = .findDrafts(subjectDigest: searchDigest)
            screen = .loading
        case .lookup, .copy:
            guard identity != nil else { reset(panelText("Mail could not identify the original message.")); return }
            if operation == .copy && (previous == nil || !canCopy) { return }
            action = selectedIdentity == nil ? .lookup : .verifiedLookup
            if operation == .lookup { screen = .loading }
        case .regenerate:
            guard let previous else { return }
            identity = selectedIdentity ?? (try? original?.evidence(requiresSource: false))?.identity
            guard identity != nil else {
                reset(panelText("Mail could not identify the original message.")); return
            }
            action = .regenerate(version: previous.version)
        case .generate:
            guard let original, case let .firstDraft(offer) = screen else { return }
            guard let evidence = try? original.evidence(requiresSource: offer.requiresOriginal) else {
                reset(panelText("Mail could not provide a readable original message.")); return
            }
            identity = evidence.identity
            action = .generate(version: offer.version, original: evidence.source)
        }
        busy = operation
        feedback = nil
        task = Task {
            defer {
                if !Task.isCancelled { busy = nil; task = nil }
            }
            do {
                var response = try await exchange.send(sessionID: sessionID, identity: identity, action: action)
                try Task.checkCancellation()
                if response == .verifyOriginal, action == .lookup {
                    guard let original, let evidence = try? original.evidence(requiresSource: false) else {
                        reset(panelText("Mail could not identify the original message.")); return
                    }
                    response = try await exchange.send(sessionID: sessionID, identity: evidence.identity, action: .verifiedLookup)
                    try Task.checkCancellation()
                }
                switch response {
                case let .draftChoices(choices):
                    guard operation == .findDrafts else { showFailure(for: operation); return }
                    if choices.isEmpty { showEmptySearch() }
                    else { screen = .draftChoices(choices) }
                case let .ready(latest):
                    guard operation != .findDrafts else { showFailure(for: operation); return }
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
                    guard selectedIdentity == nil, original != nil else { showEmptySearch(); return }
                    suggestion = nil
                    body = ""
                    screen = .firstDraft(offer)
                case .verifyOriginal:
                    reset(panelText("Mail could not identify the original message."))
                case .preparing:
                    suggestion = nil
                    body = ""
                    screen = .preparing
                case .noDraft:
                    if original == nil || selectedIdentity != nil { showEmptySearch() }
                    else { reset(panelText("No reply suggestion is ready for this message.")) }
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

    private func clearSelection() {
        selectedIdentity = nil
        suggestion = nil
        body = ""
        feedback = nil
    }

    private func showEmptySearch() {
        clearSelection()
        screen = .searchSubject(emptyResult: true)
    }

    private func reset(_ message: String) {
        clearSelection()
        screen = .message(message)
    }
}

private struct ComposeSuggestionView: View {
    @ObservedObject var model: ComposeSuggestionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(verbatim: panelText("Reply suggestion")).font(.headline)
                if case .editing = model.screen, model.canChangeChoice {
                    Spacer()
                    Button { model.beginChoosing() } label: { Text(verbatim: panelText("Choose Existing Draft")) }
                        .disabled(model.busy != nil)
                }
            }
            switch model.screen {
            case .loading:
                ProgressView { Text(verbatim: panelText("Loading suggestion…")) }
                    .controlSize(.small)
                Spacer(minLength: 0)
            case .message(let message):
                Text(verbatim: message).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            case .missingMessageID:
                Button { model.findDraft() } label: { Text(verbatim: panelText("Find Draft")) }
                Button { model.beginChoosing() } label: { Text(verbatim: panelText("Choose Existing Draft")) }
                Spacer(minLength: 0)
            case .chooseDraft:
                if !model.hasSubjectHint {
                    Text(verbatim: panelText("Reply to or forward a message to see its suggestion.")).foregroundStyle(.secondary)
                }
                Button { model.beginChoosing() } label: { Text(verbatim: panelText("Choose Existing Draft")) }
                Spacer(minLength: 0)
            case let .searchSubject(emptyResult):
                if emptyResult { Text(verbatim: panelText("No draft yet")).foregroundStyle(.secondary) }
                TextField(text: $model.searchText) { Text(verbatim: panelText("Original Subject")) }
                    .accessibilityLabel(Text(verbatim: panelText("Original Subject")))
                    .onSubmit { model.search() }
                Button { model.search() } label: { Text(verbatim: panelText("Search")) }
                    .disabled(!model.canSearch)
                Spacer(minLength: 0)
            case let .draftChoices(choices):
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(choices.indices, id: \.self) { index in
                            let choice = choices[index]
                            Button { model.choose(choice) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: choice.sender)
                                    Text(choice.capturedAt, format: .dateTime.year().month().day().hour().minute().second())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            case let .firstDraft(offer):
                Text(verbatim: panelText("No draft yet")).foregroundStyle(.secondary)
                Spacer(minLength: 0)
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
                        .help(Text(verbatim: panelText("Use %@ to draft a new reply to the original message.", offer.agentName)))
                        .accessibilityHint(Text(verbatim: panelText("Use %@ to draft a new reply to the original message.", offer.agentName)))
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
