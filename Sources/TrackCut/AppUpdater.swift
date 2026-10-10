import Combine
import Foundation
import Sparkle

/// Updates the app from GitHub Releases with Sparkle.
///
/// Sparkle reads the feed URL and the public key from Info.plist, which only the bundle built by
/// build-app.sh has. A binary started with `swift run`, or the tests, get no updater, and the menu
/// item stays disabled.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater(bundle: .main)

    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController?

    init(bundle: Bundle) {
        guard bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            controller = nil
            return
        }
        // Starting the updater schedules the automatic checks (SUEnableAutomaticChecks in Info.plist)
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
