// Sparkle auto-update wiring. Active only in the Xcode release build (where the
// Sparkle package is linked and its framework is embedded); excluded from the
// plain `swift build`/`swift run` dev path via `#if canImport(Sparkle)`.
#if canImport(Sparkle)
import Sparkle
import SwiftUI

@MainActor
final class UpdaterController {
    static let shared = UpdaterController()
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    func checkForUpdates() { controller.updater.checkForUpdates() }
}

/// `Check for Updates…` menu item, placed under the app menu.
struct CheckForUpdatesCommand: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdaterController.shared.checkForUpdates() }
        }
    }
}
#endif
