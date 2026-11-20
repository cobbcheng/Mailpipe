import SwiftUI
import Sparkle

@MainActor
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false
    private(set) var installationPending = false

    func start() {
        // Isolated workbench previews must never contact the production update feed.
        guard controller == nil, !ProcessInfo.processInfo.arguments.contains("--pipeline-directory") else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.startUpdater()
    }

    func check() {
        controller?.checkForUpdates(nil)
    }

    // Sparkle can also finish a staged installation on a normal quit. Guard both
    // that path and the installer's own AppKit termination request.
    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        installationPending = true
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if state.stage == .installing { installationPending = choice != .skip }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if error != nil { installationPending = false }
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updates: AppUpdates

    var body: some View {
        Button(L("Check for Updates…"), action: updates.check)
            .disabled(!updates.canCheck)
    }
}
