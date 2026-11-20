import Foundation
import MailpipeCore
import HarnessAdapters

extension ReplyPipeline {
    private enum ComposeLookup {
        case context(ComposeContext)
        case response(ComposePanelResponse)
    }

    private struct ComposeContext {
        let item: StoredReply?
        let settings: PipelineSettings
        let installation: HarnessInstallation
        let agentName: String
        let version: String

        var response: ComposePanelResponse {
            guard let item else { return .canGenerate(.init(version: version, agentName: agentName, requiresOriginal: true)) }
            if item.isReadyForComposeSuggestion(settings: settings, now: Date()) {
                return .ready(.init(body: item.displayedBody, version: version, agentName: agentName))
            }
            if item.isPreparing { return .preparing }
            if item.canGenerateFirstComposeDraft {
                return .canGenerate(.init(version: version, agentName: agentName, requiresOriginal: false))
            }
            return .noDraft
        }
    }

    /// Looking up the original never starts a run. Generation requires the version of the displayed offer.
    public func handleComposePanelRequest(_ request: ComposePanelRequest,
        prepareRecord: @escaping @MainActor @Sendable (String) -> Bool = { _ in true },
        isActive: @escaping @MainActor @Sendable () -> Bool) async -> ComposePanelResponse {
        do {
            guard !Task.isCancelled, isActive() else { return .unavailable }
            let lookup: @MainActor @Sendable () throws -> ComposeLookup? = { [self] in
                try composeLookup(for: request, prepareRecord: prepareRecord)
            }
            guard let result = try lookup() else {
                switch request.action {
                case .findDrafts: return .draftChoices([])
                case .lookup, .verifiedLookup: return .noDraft
                case .generate, .regenerate: return .changed
                }
            }
            let context: ComposeContext
            switch result {
            case let .response(response): return response
            case let .context(found): context = found
            }
            let current: @MainActor @Sendable () throws -> ComposeContext? = {
                guard case let .context(latest) = try lookup() else { return nil }
                return latest
            }
            switch request.action {
            case .findDrafts: return .failed
            case .lookup: return context.response
            case .verifiedLookup:
                let response = context.response
                guard case .ready = response else { return .noDraft }
                return response
            case let .generate(version, original):
                guard case .canGenerate = context.response, context.version == version else { return .changed }
                return try await generateFirstSuggestion(for: request, original: original, context: context,
                                                         current: current, isActive: isActive)
            case let .regenerate(version):
                guard let item = context.item, case let .ready(suggestion) = context.response, version == suggestion.version else { return .changed }
                return try await regenerateSuggestion(for: request, context: context, item: item) {
                    guard !Task.isCancelled, isActive(), let latest = try current(), case .ready = latest.response,
                          latest.version == version else { throw PipelineError.revoked }
                }
            }
        } catch PipelineError.revoked { return .changed }
        catch { return .failed }
    }

    private func composeLookup(for request: ComposePanelRequest, prepareRecord: (String) -> Bool) throws -> ComposeLookup? {
        let settings = try store.settings()
        guard !settings.paused, let executable = settings.executable, executable.hasPrefix("/"),
              let permission = settings.permission else { return nil }
        if settings.harnessKind == .opencode {
            guard let target = settings.openCodeModel, OpenCodeDialect.validModelReference(target) else { return nil }
        }
        if case let .findDrafts(subjectDigest) = request.action {
            guard request.identity == nil else { return nil }
            return .response(.draftChoices(try store.composeDraftChoices(subjectDigest: subjectDigest, settings: settings, now: Date())))
        }
        guard let identity = request.identity else { return nil }
        let candidates = try store.composeCandidates(messageIDDigest: identity.messageIDDigest)
        // Resolve identity before eligibility. Discarded or revoked duplicates cannot break a tie.
        var matches: [StoredReply] = []
        for item in candidates {
            guard let storedIdentity = item.composeIdentity(includingBody: identity.displayBodyDigest != nil) else { return nil }
            if identity.matches(storedIdentity) { matches.append(item) }
        }
        if request.action == .lookup, identity.displayBodyDigest == nil,
           matches.contains(where: { $0.isReadyForComposeSuggestion(settings: settings, now: Date()) }) {
            return .response(.verifyOriginal)
        }
        guard matches.count <= 1 else { return nil }
        let item: StoredReply?
        if let matched = matches.first?.id {
            guard prepareRecord(matched), let record = try store.record(matched),
                  record.isAuthorizedForCompose(settings: settings, now: Date()) else { return nil }
            item = record
        } else {
            guard request.action != .verifiedLookup, candidates.isEmpty, permission.delivery == .mailKit,
                  permission.exactSubject.map({ ComposeMessageIdentity.digest(forSubject: $0) == identity.subjectDigest }) ?? true,
                  try store.canAddComposeOriginal() else { return nil }
            item = nil
        }
        let installation = HarnessInstallation(kind: settings.harnessKind, executable: URL(fileURLWithPath: executable),
                                               openCodeModel: settings.openCodeModel)
        // Opening and confirming use the same message envelope. The full source is checked separately on submission.
        var binding = [request.sessionID.uuidString, permission.id.uuidString, settings.revision.uuidString,
                       installation.id, installation.openCodeModel ?? "", identity.messageIDDigest, identity.envelopeDigest]
        if let item {
            binding += [item.id, item.state.rawValue, item.runs.last?.destination.runID ?? "",
                        item.draftVersion ?? "", item.input.subject, item.input.body, item.displayedSubject, item.displayedBody]
        }
        let version = contentDigest(try JSONEncoder().encode(binding))
        let target: String
        switch installation.kind {
        case .opencode: target = installation.openCodeModel ?? installation.kind.displayName
        case .deepseek, .hermes, .openclaw: target = "DeepSeek"
        case .codex: target = "OpenAI"
        case .claude: target = "Claude"
        }
        return .context(ComposeContext(item: item, settings: settings, installation: installation,
                                      agentName: installation.kind.displayName + " · " + target, version: version))
    }

    private func generateFirstSuggestion(for panel: ComposePanelRequest, original: ComposePanelOriginal?, context: ComposeContext,
        current: @escaping @MainActor @Sendable () throws -> ComposeContext?,
        isActive: @escaping @MainActor @Sendable () -> Bool) async throws -> ComposePanelResponse {
        guard let permission = context.settings.permission else { return .unavailable }
        var item: StoredReply
        if let stored = context.item {
            guard original == nil, !stored.runs.contains(where: { $0.destination.runID == panel.id.uuidString }) else { return .changed }
            if stored.mailKitBody != true {
                _ = try await resolveComposeOriginal(stored, settings: context.settings)
            }
            item = stored
            if stored.state == .needsReview { item.regenerationCount = (item.regenerationCount ?? 0) + 1 }
        } else {
            guard let original, let identity = panel.identity, original.matches(identity), permission.accepts(original.subject) else { return .changed }
            let id = UUID().uuidString
            let messageID = original.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            item = StoredReply(id: id, permissionID: permission.id, capturedAt: Date(), messageID: messageID,
                               input: MailInput(messageRef: id, subject: original.subject, body: original.body), state: .drafting)
            item.mailKitBody = true
            item.displayBody = original.displayBody
            item.correspondents = MailCorrespondents(sender: original.sender, recipients: original.to, cc: original.cc)
        }
        guard !Task.isCancelled, isActive() else { return .unavailable }
        item.error = nil
        item.level = context.settings.level
        item.revision = context.settings.revision
        let source = item.input
        let runID = panel.id.uuidString
        let task = try ReplyDraftRequest(message: source, replyInstructions: context.settings.replyInstructions, allowsPullRequestReview: false)
        try await generateDraft(for: item, request: task, installation: context.installation, runID: runID, confirmStart: {
            // Check and reserve on the same actor turn, including after scope revalidation.
            guard !Task.isCancelled, isActive(), let latest = try current(), latest.version == context.version,
                  case .canGenerate = latest.response else { throw PipelineError.revoked }
        }) {
            guard !Task.isCancelled, isActive(), let latest = try current(),
                  latest.settings.revision == context.settings.revision, latest.installation.id == context.installation.id,
                  let record = latest.item, record.input == source, record.state == .drafting, record.draftData == nil,
                  record.editedBody == nil, record.editedSubject == nil, record.runs.last?.destination.runID == runID
            else { throw PipelineError.revoked }
        }
        guard !Task.isCancelled, isActive(), let latest = try current(), latest.item?.id == item.id else { return .changed }
        if case .ready = latest.response { return latest.response }
        return latest.item?.error == PipelineError.revoked.rawValue ? .changed : .failed
    }

    private func regenerateSuggestion(for panel: ComposePanelRequest, context: ComposeContext, item original: StoredReply,
                                      authorize: @escaping @MainActor @Sendable () throws -> Void) async throws -> ComposePanelResponse {
        var item = original
        let runID = panel.id.uuidString
        guard !item.isRegeneratingInCompose, !item.runs.contains(where: { $0.finishedAt == nil }),
              item.composeRegenerationRuns?.contains(where: { $0.destination.runID == runID }) != true else { return .changed }
        guard !item.regenerationLimitReached else { return .regenerationLimitReached }
        let task = try ReplyDraftRequest(message: item.input, replyInstructions: context.settings.replyInstructions,
                                         allowsPullRequestReview: false)
        let kind = context.installation.kind
        let destination = try DataDestination(messageRef: item.id, runID: runID, taskKind: .draft, harness: kind)
        var receipt = PipelineRun(destination: destination, startedAt: Date())
        var runs = item.composeRegenerationRuns ?? []
        runs.append(receipt)
        item.composeRegenerationRuns = runs
        try store.save(item)
        let response: ComposePanelResponse
        do {
            let route = item.mailKitBody == true
                ? AccountRoute(mailKitPermission: item.permissionID, allowedHarnesses: [kind])
                : AccountRoute(accountID: item.accountID, allowedHarnesses: [kind])
            if item.mailKitBody != true {
                // Scope-based captures require fresh proof that the original is still in the authorized inbox.
                _ = try await resolveComposeOriginal(item, settings: context.settings)
                try authorize()
            }
            let output = try await model(context.installation).run(.draft(task), route: route) { try await authorize() }
            try receipt.record(output, installation: context.installation)
            try authorize()
            let result = try ReplyDraft.validated(output.content, for: task)
            response = .ready(ComposePanelSuggestion(body: result.body, version: context.version,
                                                      agentName: context.agentName))
        } catch {
            let revoked = (error as? PipelineError) == .revoked || error is CancellationError
            receipt.error = (error as? MailpipeError)?.rawValue ?? (revoked ? "revoked" : "operationFailed")
            response = revoked ? .changed : .failed
        }
        receipt.finishedAt = Date()
        // The user may have edited or discarded the workbench draft while the agent ran.
        guard var current = try store.record(item.id), var currentRuns = current.composeRegenerationRuns,
              let index = currentRuns.firstIndex(where: { $0.destination.runID == runID }) else { return .changed }
        currentRuns[index] = receipt
        current.composeRegenerationRuns = currentRuns
        try store.save(current)
        return response
    }
}
