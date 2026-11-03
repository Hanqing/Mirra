import Combine
import Foundation
import Sparkle

/// Automatic updates via Sparkle. The feed (appcast.xml) is served by GitHub Pages and
/// points at the zips attached to GitHub Releases; every zip is EdDSA-signed by the release script.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateController()

    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecks = false {
        didSet { updater?.automaticallyChecksForUpdates = automaticallyChecks }
    }
    @Published var automaticallyDownloads = false {
        didSet { updater?.automaticallyDownloadsUpdates = automaticallyDownloads }
    }

    private var controller: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { controller?.updater }

    /// Updates only make sense for the packaged app, not `swift run`.
    var isAvailable: Bool { controller != nil }

    override init() {
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloads = controller.updater.automaticallyDownloadsUpdates
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Development: silently download and stage an update, installed when the app quits.
    func checkInBackgroundForTesting() {
        updater?.automaticallyDownloadsUpdates = true
        updater?.checkForUpdatesInBackground()
    }

    // MARK: SPUUpdaterDelegate

    /// `MIRRA_FEED_URL` points a development build at a local test feed.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["MIRRA_FEED_URL"]
    }
}
