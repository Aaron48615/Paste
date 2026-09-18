import CoreGraphics
import Foundation

/// Geometry shared by palette restoration and the settings window's screen limits.
enum WindowPlacement {
    /// Use the system's usable frame so bottom and side Docks are both respected.
    static func pastFrame(visibleFrame: NSRect, preferredHeight: CGFloat, preferredWidth: CGFloat? = nil) -> NSRect {
        let width = min(preferredWidth ?? max(1, visibleFrame.width - 16), max(1, visibleFrame.width - 16))
        return NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.minY + 8,
            width: width,
            height: max(1, min(preferredHeight, visibleFrame.height - 16)))
    }

    static func clamp(_ frame: NSRect, to bounds: NSRect) -> NSRect {
        let width = min(frame.width, max(1, bounds.width))
        let height = min(frame.height, max(1, bounds.height))
        return NSRect(
            x: min(max(frame.minX, bounds.minX), bounds.maxX - width),
            y: min(max(frame.minY, bounds.minY), bounds.maxY - height),
            width: width, height: height)
    }

    static func settingsHeight(visibleHeight: CGFloat) -> CGFloat {
        min(720, max(1, visibleHeight - 32))
    }
}

/// Stores the user's preference separately from temporary screen-constrained geometry.
struct PaletteSizeStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private struct SavedSize: Codable {
        let width: Double
        let height: Double
    }

    func load(style: String) -> CGSize? {
        guard let data = defaults.data(forKey: "paletteSize.\(style)"),
              let saved = try? JSONDecoder().decode(SavedSize.self, from: data),
              saved.width.isFinite, saved.height.isFinite,
              saved.width > 0, saved.height > 0 else { return nil }
        return CGSize(width: saved.width, height: saved.height)
    }

    func save(_ size: CGSize, style: String) {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              let data = try? JSONEncoder().encode(SavedSize(width: size.width, height: size.height))
        else { return }
        defaults.set(data, forKey: "paletteSize.\(style)")
    }
}

/// Split preferences survive temporary minimum-size constraints without being overwritten.
enum DaycastSplitLayout {
    static let dividerThickness: CGFloat = 9

    static func availableLength(_ total: CGFloat) -> CGFloat {
        max(0, total - dividerThickness)
    }

    static func listLength(total: CGFloat, ratio: Double, compact: Bool) -> CGFloat {
        let available = availableLength(total)
        let preferred = ratio.isFinite && ratio > 0 && ratio < 1
            ? available * ratio : (compact ? available * 0.45 : 290)
        return constrainedLength(preferred, total: total, compact: compact)
    }

    static func constrainedLength(_ proposed: CGFloat, total: CGFloat, compact: Bool) -> CGFloat {
        let available = availableLength(total)
        let listMinimum: CGFloat = compact ? 120 : 220
        let previewMinimum: CGFloat = compact ? 140 : 260
        // On unusually small screens both panes retain a share of the available space.
        let scale = min(1, available / (listMinimum + previewMinimum))
        return min(max(proposed, listMinimum * scale), available - previewMinimum * scale)
    }

    static func ratio(for length: CGFloat, total: CGFloat, compact: Bool) -> Double {
        let available = availableLength(total)
        guard available > 0 else { return compact ? 0.45 : 0.4 }
        return constrainedLength(length, total: total, compact: compact) / available
    }
}
