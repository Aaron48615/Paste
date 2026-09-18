import Combine
import Foundation
import Sparkle

/// Owns Sparkle for the lifetime of the app and exposes only the controls used by Paste's UI.
/// Sparkle persists its own preferences; Paste deliberately does not duplicate them in AppSettings.
@MainActor
final class UpdateService: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false

    let isConfigured: Bool
    private let updaterController: SPUStandardUpdaterController?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        isConfigured = info["RePasteUpdatesEnabled"] as? Bool == true
            && (info["SUFeedURL"] as? String)?.hasPrefix("https://") == true
            && !(info["SUPublicEDKey"] as? String ?? "").isEmpty
        guard isConfigured else {
            updaterController = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        updaterController = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    func start() {
        updaterController?.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updaterController?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater = updaterController?.updater else { return }
        guard updater.automaticallyChecksForUpdates != enabled else { return }
        updater.automaticallyChecksForUpdates = enabled
    }
}
