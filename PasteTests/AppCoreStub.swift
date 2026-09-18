import Foundation

/// Minimal stand-in for the app's `AppCore` god object.
///
/// The test bundle compiles a small subset of app sources directly. Of those, only
/// `CopySelectionOnSelect.swift` and the item gesture adapter touch `AppCore.shared.settings`,
/// so this shim provides just that surface. The real `AppCore.swift` is deliberately NOT part
/// of this target, so there is no duplicate-symbol conflict.
@MainActor
final class AppCore {
    static let shared = AppCore()

    let settings = AppSettings()

    private init() {}
}
