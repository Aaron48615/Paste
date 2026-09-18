import AppKit
import SwiftUI

@MainActor
final class PaletteWindowController: NSObject, NSWindowDelegate {
    private unowned let core: AppCore
    private var panel: PalettePanel?
    private var panelStyle: PaletteVisualStyle?
    private(set) var previousApp: NSRunningApplication?

    init(core: AppCore) {
        self.core = core
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let frontmost, frontmost.processIdentifier != NSRunningApplication.current.processIdentifier, !frontmost.isTerminated {
            previousApp = frontmost
        } else if previousApp == nil || previousApp?.isTerminated == true {
            previousApp = NSWorkspace.shared.runningApplications.first {
                $0.activationPolicy == .regular
                && $0.processIdentifier != NSRunningApplication.current.processIdentifier
                && !$0.isTerminated
            }
        }
        let target = PasteTarget(app: previousApp)
        core.palette.pasteTarget = target
        if let path = target?.iconPath {
            _ = IconCache.icon(forFile: path)
        }

        let panel = ensurePanel()
        let restoredPosition = restorePosition(panel)
        let animateEntrance = !restoredPosition && !panel.isVisible && core.settings.paletteVisualStyle == .past
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !restoredPosition { position(panel) }
        let destination = panel.frame
        if animateEntrance {
            panel.setFrameOrigin(NSPoint(x: destination.minX, y: destination.minY - destination.height))
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        if core.settings.switchToEnglishInputOnOpen {
            InputSourceSwitcher.selectEnglish()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
        panel.orderFrontRegardless()
        if animateEntrance {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(destination, display: true)
            }
        }
        panel.requestSearchFocus()
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible, !panel.isKeyWindow else { return }
            panel.makeKeyAndOrderFront(nil)
            panel.requestSearchFocus()
        }
    }

    func hide(restoreFocus: Bool) {
        panel?.orderOut(nil)
        ImageThumbnail.purgePreviews()
        if core.settings.switchToEnglishInputOnOpen {
            InputSourceSwitcher.restore()
        }
        if restoreFocus { previousApp?.activate() }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        core.hidePalette(restoreFocus: false)
    }

    private func ensurePanel() -> PalettePanel {
        let style = core.settings.paletteVisualStyle
        if let panel, panelStyle == style { return panel }
        panel?.orderOut(nil)
        let root = RootPaletteView(visualStyle: style)
            .environmentObject(core)
            .environmentObject(core.palette)
            .environmentObject(core.clipboardStore)
        let panel = PalettePanel(rootView: root, visualStyle: core.settings.paletteVisualStyle)
        panel.onUserDragEnded = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.savePosition(panel, style: style)
        }
        panel.delegate = self
        panel.paletteViewModel = core.palette
        self.panel = panel
        panelStyle = style
        return panel
    }

    private func position(_ panel: PalettePanel) {
        guard let screen = targetScreen() else { return }
        let visible = screen.visibleFrame
        let visualStyle = core.settings.paletteVisualStyle
        if visualStyle == .past {
            panel.setFrame(
                WindowPlacement.pastFrame(
                    visibleFrame: visible, preferredHeight: Theme.Size.pastPanelHeight),
                display: true)
            return
        }
        let panelSize = Theme.Size.panelSize(for: visualStyle)
        let width = min(panelSize.width, max(1, visible.width - 32))
        let height = min(panelSize.height, max(1, visible.height - 32))
        let topEdge = visible.maxY
            - visible.height * Theme.Size.paletteTopMarginFraction(for: visualStyle)
        panel.applyVisualStyle(visualStyle)
        panel.setFrame(
            NSRect(
                x: visible.midX - width / 2,
                y: topEdge - height,
                width: width,
                height: height),
            display: true)
    }

    private struct SavedPosition: Codable {
        let displayID: UInt32
        let x: Double
        let y: Double
    }

    private func positionKey(_ style: PaletteVisualStyle) -> String {
        "palettePosition.\(style.rawValue)"
    }

    private func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func savePosition(_ panel: PalettePanel, style: PaletteVisualStyle) {
        // Past always reopens at the current screen's usable bottom edge.
        guard style == .daycast, let screen = panel.screen else { return }
        let position = SavedPosition(
            displayID: displayID(screen),
            x: panel.frame.minX - screen.visibleFrame.minX,
            y: panel.frame.minY - screen.visibleFrame.minY)
        guard let data = try? JSONEncoder().encode(position) else { return }
        UserDefaults.standard.set(data, forKey: positionKey(style))
    }

    private func restorePosition(_ panel: PalettePanel) -> Bool {
        let style = core.settings.paletteVisualStyle
        guard style == .daycast,
            let data = UserDefaults.standard.data(forKey: positionKey(style)),
            let saved = try? JSONDecoder().decode(SavedPosition.self, from: data),
            saved.x.isFinite, saved.y.isFinite,
            let screen = NSScreen.screens.first(where: { displayID($0) == saved.displayID }) ?? targetScreen()
        else { return false }
        let visible = screen.visibleFrame
        let preferred = Theme.Size.panelSize(for: style)
        let size = NSSize(
            width: min(preferred.width, max(1, visible.width - 16)),
            height: min(preferred.height, max(1, visible.height - 16)))
        let frame = NSRect(
            x: visible.minX + saved.x, y: visible.minY + saved.y,
            width: size.width, height: size.height)
        panel.applyVisualStyle(style)
        panel.setFrame(WindowPlacement.clamp(frame, to: visible.insetBy(dx: 8, dy: 8)), display: true)
        return true
    }

    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}
