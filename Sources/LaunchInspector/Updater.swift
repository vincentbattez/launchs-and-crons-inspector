// Sparkle auto-update wiring. Active only in the Xcode release build (where the
// Sparkle package is linked and its framework is embedded); excluded from the
// plain `swift build`/`swift run` dev path via `#if canImport(Sparkle)`.
#if canImport(Sparkle)
import Sparkle
import SwiftUI

@MainActor
final class UpdaterController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdaterController()

    /// True once a valid update has been found — drives the in-app update button.
    @Published private(set) var updateAvailable = false

    private var controller: SPUStandardUpdaterController!

    override private init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        // Silent probe at launch: sets `updateAvailable` via the delegate, no dialog.
        controller.updater.checkForUpdateInformation()
    }

    /// User asked to update (toolbar button or menu) — show Sparkle's install flow.
    func installUpdate() { controller.updater.checkForUpdates() }

    // MARK: SPUUpdaterDelegate (called by Sparkle; hop to the main actor to mutate state)

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in UpdaterController.shared.updateAvailable = true }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in UpdaterController.shared.updateAvailable = false }
    }
}

/// Toolbar button shown only when an update is available; tap installs it.
struct UpdateToolbarButton: View {
    @ObservedObject private var updater = UpdaterController.shared

    var body: some View {
        if updater.updateAvailable {
            Button {
                updater.installUpdate()
            } label: {
                Label("Update available", systemImage: "arrow.down.circle.fill")
            }
            .help("A new version is available — click to update")
            .tint(.green)
        }
    }
}

/// `Check for Updates…` menu item, placed under the app menu.
struct CheckForUpdatesCommand: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdaterController.shared.installUpdate() }
        }
    }
}
#endif
