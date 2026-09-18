import CoreGraphics
import Foundation

/// Geometry shared by palette restoration and the settings window's screen limits.
enum WindowPlacement {
    /// Use the system's usable frame so bottom and side Docks are both respected.
    static func pastFrame(visibleFrame: NSRect, preferredHeight: CGFloat) -> NSRect {
        NSRect(
            x: visibleFrame.minX + 8,
            y: visibleFrame.minY + 8,
            width: max(1, visibleFrame.width - 16),
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
