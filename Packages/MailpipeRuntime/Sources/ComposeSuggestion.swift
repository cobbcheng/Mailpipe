import Foundation
import MailpipeCore
import HarnessAdapters

extension ReplyPipeline {
    private struct ComposeContext {
        let item: StoredReply
        let installation: HarnessInstallation
        let suggestion: ComposePanelSuggestion
    }

    /// Only a claimed request for a live compose panel may release text or invoke a model.
    public func handleComposePanelRequest(_ request: ComposePanelRequest,
        prepareRecord: @escaping @MainActor @Sendable (String) -> Bool = { _ in true },
        isActive: @escaping @MainActor @Sendable () -> Bool) async -> ComposePanelResponse {
        do {
            guard !Task.isCancelled, isActive() else { return .unavailable }
            guard let context = try composeContext(for: request, prepareRecord: prepareRecord) else {
                if case .shorten = request.action { return .changed }
                return .noDraft
            }
            switch request.action {
            case .lookup: return .ready(context.suggestion)
            case let .shorten(version, body):
                guard version == context.suggestion.version else { return .changed }
                return try await shorten(body, for: request, context: context) { [self] in
                    guard !Task.isCancelled, isActive(),
                          let current = try composeContext(for: request, prepareRecord: prepareRecord),
                          current.suggestion.version == version else { throw PipelineError.revoked }
                }
            }
        } catch { return .failed }
    }

    private func composeContext(for request: ComposePanelRequest, prepareRecord: (String) -> Bool) throws -> ComposeContext? {
        let settings = try store.settings()
        guard !settings.paused, let executable = settings.executable, executable.hasPrefix("/"),
              settings.permission != nil else { return nil }
        let candidates = try store.composeCandidates(messageIDDigest: request.identity.messageIDDigest)
        // Resolve identity before eligibility. Discarded or revoked duplicates cannot break a tie.
        var matched: String?
        for item in candidates {
            guard let id = item.messageID, let addresses = item.correspondents, let sender = addresses.sender,
                  let identity = ComposeMessageIdentity(messageID: id, subject: item.input.subject, sender: sender,
                      to: addresses.recipients, cc: addresses.cc, displayBody: item.displayBody ?? item.input.body)
            else { return nil }
            if request.identity.matches(identity) {
                guard matched == nil else { return nil }
                matched = item.id
            }
        }
        guard let matched, prepareRecord(matched), let item = try store.record(matched),
              item.isReadyForComposeSuggestion(settings: settings, now: Date()), let draftVersion = item.draftVersion
        else { return nil }
        if settings.harnessKind == .opencode {
            guard let target = settings.openCodeModel, OpenCodeDialect.validModelReference(target) else { return nil }
        }
        let installation = HarnessInstallation(kind: settings.harnessKind, executable: URL(fileURLWithPath: executable),
                                               openCodeModel: settings.openCodeModel)
        // Include local edits and the chosen destination. An old confirmation cannot dispatch to a new agent.
        let binding = [request.sessionID.uuidString, item.id, item.permissionID.uuidString, settings.revision.uuidString,
                       installation.id, installation.openCodeModel ?? "", draftVersion, item.displayedSubject, item.displayedBody]
        let version = contentDigest(try JSONEncoder().encode(binding))
        let target: String
        switch installation.kind {
        case .opencode: target = installation.openCodeModel ?? installation.kind.displayName
        case .deepseek, .hermes, .openclaw: target = "DeepSeek"
        case .codex: target = "OpenAI"
        case .claude: target = "Claude"
        }
        let suggestion = ComposePanelSuggestion(body: item.displayedBody, version: version,
            agentName: installation.kind.displayName + " · " + target)
        return ComposeContext(item: item, installation: installation, suggestion: suggestion)
    }

    private func shorten(_ body: String, for panel: ComposePanelRequest, context: ComposeContext,
                         authorize: @escaping @MainActor @Sendable () throws -> Void) async throws -> ComposePanelResponse {
        var item = context.item
        let runID = panel.id.uuidString
        guard !item.isShortening, !item.runs.contains(where: { $0.finishedAt == nil }),
              item.composeShortenRuns?.contains(where: { $0.destination.runID == runID }) != true else { return .changed }
        let task = try ReplyDraftRequest(shortening: body, operationID: panel.id)
        let kind = context.installation.kind
        let destination = try DataDestination(messageRef: item.id, runID: runID, taskKind: .draft, harness: kind)
        var receipt = PipelineRun(destination: destination, startedAt: Date())
        var runs = item.composeShortenRuns ?? []
        runs.append(receipt)
        item.composeShortenRuns = runs
        try store.save(item)
        let response: ComposePanelResponse
        do {
            let route = item.mailKitBody == true
                ? AccountRoute(mailKitPermission: item.permissionID, allowedHarnesses: [kind])
                : AccountRoute(accountID: item.accountID, allowedHarnesses: [kind])
            let output = try await model(context.installation).run(.draft(task), route: route) { try await authorize() }
            try receipt.record(output, installation: context.installation)
            try authorize()
            let result = try ReplyDraft.validated(output.content, for: task)
            guard result.body.trimmingCharacters(in: .whitespacesAndNewlines).count <
                    body.trimmingCharacters(in: .whitespacesAndNewlines).count else { throw MailpipeError.invalidOutput }
            response = .ready(ComposePanelSuggestion(body: result.body, version: context.suggestion.version,
                                                      agentName: context.suggestion.agentName))
        } catch {
            let revoked = (error as? PipelineError) == .revoked || error is CancellationError
            receipt.error = (error as? MailpipeError)?.rawValue ?? (revoked ? "revoked" : "operationFailed")
            response = revoked ? .changed : .failed
        }
        receipt.finishedAt = Date()
        // The user may have edited or discarded the workbench draft while the agent ran.
        guard var current = try store.record(item.id), var currentRuns = current.composeShortenRuns,
              let index = currentRuns.firstIndex(where: { $0.destination.runID == runID }) else { return .changed }
        currentRuns[index] = receipt
        current.composeShortenRuns = currentRuns
        try store.save(current)
        return response
    }
}
