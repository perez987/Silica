import Combine
import Sparkle

/// Updates through Sparkle. The feed (SUFeedURL in Config/Info.plist) is served by
/// GitHub Pages from docs/appcast.xml, and each update in it is a DMG attached to a
/// GitHub release; scripts/release.sh publishes both. Updates are verified against
/// SUPublicEDKey before they install.
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// False while a check or an update is already under way.
    @Published private(set) var canCheckForUpdates = false

    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private init() {
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Whether Sparkle checks the feed once a day in the background.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
