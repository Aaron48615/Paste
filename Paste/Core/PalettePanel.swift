import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

/// The sole keyboard gateway for the palette window. It receives key events before the current
/// first responder, so embedded AppKit views and SwiftUI focus changes cannot disable commands.
final class PalettePanel: NSPanel {
    private let visualStyle: PaletteVisualStyle
    lazy var itemInteractions = PaletteItemInteractionController(panel: self, style: visualStyle)
    var onUserDragEnded: (() -> Void)?
    var onUserResizeEnded: (() -> Void)?
    var auxiliaryInputActive = false
    weak var paletteViewModel: PaletteViewModel? {
        didSet {
            paletteViewModel?.onMenuOpenChanged = { [weak self] open in
                self?.setSearchCaretHidden(open)
            }
            paletteViewModel?.onSearchFocusRequested = { [weak self] in
                self?.requestSearchFocus()
            }
        }
    }

    private weak var resizeSurface: PaletteResizeSurface?
    private weak var searchField: NSTextField?
    private weak var renameField: NSTextField?
    private var pendingSearchFocusRequest: UUID?

    private static let relevantModifiers: NSEvent.ModifierFlags = [
        .command, .option, .control, .shift,
    ]

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let resizeSurface,
            resizeSurface.containsResizePoint(event.locationInWindow) {
            itemInteractions.cancel()
            resizeSurface.mouseDown(with: event)
            return
        }
        if itemInteractions.handle(event) { return }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            commitRenameIfClickIsOutside(event)
        }
        if event.type == .keyDown, route(event) { return }
        super.sendEvent(event)
        if event.type == .mouseMoved, let resizeSurface,
            resizeSurface.containsResizePoint(event.locationInWindow) {
            resizeSurface.cursorUpdate(with: event)
        }
    }

    override func orderOut(_ sender: Any?) {
        itemInteractions.cancel()
        super.orderOut(sender)
    }

    private func route(_ event: NSEvent) -> Bool {
        // The in-panel Pinboard editor owns text editing, Return and Escape.
        if auxiliaryInputActive { return false }
        guard let paletteViewModel else { return false }
        let keyCode = Int(event.keyCode)
        let modifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        let shortcut = KeyboardShortcuts.Shortcut(event: event)

        if modifiers == .command {
            switch keyCode {
            case kVK_ANSI_N:
                return handleOnce(.newTextItem, event: event)
            case kVK_ANSI_Comma:
                return handleOnce(.settings, event: event)
            case kVK_ANSI_Q:
                return handleOnce(.quit, event: event)
            default:
                break
            }
        }

        if paletteViewModel.renamingID != nil {
            return routeRename(event, keyCode: keyCode, modifiers: modifiers)
        }

        if modifiers == .command, keyCode == kVK_Delete {
            return paletteViewModel.handle(.clearQuery)
        }

        if PaletteShortcut.actions.matches(shortcut) {
            return handleOnce(.toggleActions, event: event)
        }
        if PaletteShortcut.copyToClipboard.matches(shortcut) {
            return handleOnce(.copy, event: event)
        }
        if PaletteShortcut.rename.matches(shortcut) {
            return handleOnce(.rename, event: event)
        }
        if PaletteShortcut.pinToScreen.matches(shortcut) {
            return handleOnce(.pinToScreen, event: event)
        }
        if PaletteShortcut.togglePin.matches(shortcut) {
            return handleOnce(.togglePin, event: event)
        }
        if PaletteShortcut.showInFinder.matches(shortcut) {
            return handleOnce(.revealInFinder, event: event)
        }

        if modifiers == .command {
            switch keyCode {
            case kVK_ANSI_C, kVK_ANSI_X, kVK_ANSI_V, kVK_ANSI_A:
                if handleEditingShortcut(keyCode) { return true }
            default:
                break
            }
        }

        if modifiers.isEmpty {
            switch keyCode {
            case kVK_DownArrow:
                return paletteViewModel.handle(.move(1))
            case kVK_UpArrow:
                return paletteViewModel.handle(.move(-1))
            case kVK_RightArrow where visualStyle == .past:
                return paletteViewModel.handle(.move(1))
            case kVK_LeftArrow where visualStyle == .past:
                return paletteViewModel.handle(.move(-1))
            case kVK_Return, kVK_ANSI_KeypadEnter:
                return handleOnce(.activate, event: event)
            case kVK_Escape:
                return paletteViewModel.handle(.cancel)
            case kVK_Space:
                if paletteViewModel.canToggleQuickLook {
                    return handleOnce(.toggleQuickLook, event: event)
                }
                // At an empty query, Space is a Quick Look gesture even when the selected item
                // cannot be previewed. Swallow it instead of starting a useless blank search.
                if paletteViewModel.queryIsEmpty {
                    return true
                }
            default:
                break
            }
        }

        // An overlay menu is modal. Unsupported keys must not leak into the search editor or the
        // read-only preview behind it.
        return paletteViewModel.menuOpen
    }

    private func routeRename(
        _ event: NSEvent, keyCode: Int, modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        if modifiers == .command {
            switch keyCode {
            case kVK_ANSI_C, kVK_ANSI_X, kVK_ANSI_V, kVK_ANSI_A:
                return handleEditingShortcut(keyCode)
            default:
                break
            }
        }
        if modifiers.isEmpty {
            switch keyCode {
            case kVK_Return, kVK_ANSI_KeypadEnter:
                // Let the active NSTextField finish editing so marked text is finalized and the
                // row editor commits its actual value instead of a separately mirrored draft.
                return false
            case kVK_Escape:
                return paletteViewModel?.handle(.cancel) ?? false
            default:
                return false
            }
        }
        return false
    }

    private func handleOnce(_ command: PaletteCommand, event: NSEvent) -> Bool {
        if event.isARepeat { return true }
        return paletteViewModel?.handle(command) ?? false
    }

    func registerSearchField(_ field: NSTextField) {
        searchField = field
        schedulePendingSearchFocus()
    }

    func registerRenameField(_ field: NSTextField) {
        renameField = field
    }

    func requestSearchFocus() {
        let request = UUID()
        pendingSearchFocusRequest = request
        scheduleSearchFocus(for: request)
    }

    private func schedulePendingSearchFocus() {
        guard let request = pendingSearchFocusRequest else { return }
        scheduleSearchFocus(for: request)
    }

    private func scheduleSearchFocus(for request: UUID) {
        DispatchQueue.main.async { [weak self] in
            _ = self?.focusSearch(for: request)
        }
    }

    @discardableResult
    private func focusSearch(for request: UUID) -> Bool {
        guard pendingSearchFocusRequest == request, isVisible, isKeyWindow, !auxiliaryInputActive,
            paletteViewModel?.renamingID == nil, let searchField, searchField.isEnabled
        else { return false }
        guard makeFirstResponder(searchField) else { return false }
        pendingSearchFocusRequest = nil
        return true
    }

    private func commitRenameIfClickIsOutside(_ event: NSEvent) {
        guard let paletteViewModel, paletteViewModel.renamingID != nil,
            let renameField
        else { return }

        let frameInWindow = renameField.convert(renameField.bounds, to: nil)
        if !renameField.isHidden, frameInWindow.contains(event.locationInWindow) { return }

        if renameField.currentEditor() != nil {
            _ = makeFirstResponder(nil)
        }
        if paletteViewModel.renamingID != nil {
            paletteViewModel.commitOpenRename(renameField.stringValue)
        }
    }

    private func setSearchCaretHidden(_ hidden: Bool) {
        guard let editor = firstResponder as? NSTextView else { return }
        editor.insertionPointColor = hidden ? .clear : .textColor
        editor.updateInsertionPointStateAndRestartTimer(!hidden)
    }

    /// This accessory app has no visible Edit menu, so route standard editing commands to the
    /// active AppKit field editor ourselves.
    private func handleEditingShortcut(_ keyCode: Int) -> Bool {
        guard paletteViewModel?.menuOpen != true, let editor = firstResponder as? NSTextView else {
            return false
        }

        switch keyCode {
        case kVK_ANSI_C:
            guard editor.selectedRange().length > 0 else { return true }
            editor.copy(nil)
            if !(editor is PreviewTextView) {
                Paster.markCurrentPasteboardInternal()
            }
            return true
        case kVK_ANSI_X:
            guard editor.isEditable, editor.selectedRange().length > 0 else { return true }
            editor.cut(nil)
            Paster.markCurrentPasteboardInternal()
            return true
        case kVK_ANSI_V:
            guard editor.isEditable else { return true }
            editor.paste(nil)
            return true
        case kVK_ANSI_A:
            editor.selectAll(nil)
            return true
        default:
            return false
        }
    }

    init<Content: View>(rootView: Content, visualStyle: PaletteVisualStyle) {
        self.visualStyle = visualStyle
        let panelSize = Theme.Size.panelSize(for: visualStyle)
        super.init(
            contentRect: NSRect(
                x: 0, y: 0, width: panelSize.width, height: panelSize.height),
            styleMask: [.borderless, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        acceptsMouseMovedEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = true
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        isReleasedWhenClosed = false

        let frame = NSRect(
            x: 0, y: 0, width: panelSize.width, height: panelSize.height)
        let hosting = TransparentPaletteHostingView(rootView: rootView)
        hosting.frame = frame
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]

        if visualStyle == .daycast {
            // Daycast owns its original vibrancy surface in SwiftUI.
            contentView = hosting
        } else if #available(macOS 26.0, *) {
            // Match Obelisk's Search Panel: the whole window is a single native glass sampling
            // surface, with SwiftUI hosted inside its content view.
            let glass = NSGlassEffectView(frame: frame)
            glass.autoresizingMask = [.width, .height]
            glass.style = .regular
            glass.cornerRadius = Self.cornerRadius(for: visualStyle)
            let content = NSView(frame: frame)
            content.autoresizingMask = [.width, .height]
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.clear.cgColor
            content.layer?.cornerRadius = Theme.Radius.pastPanel
            content.layer?.masksToBounds = true
            content.addSubview(hosting)
            glass.contentView = content

            let shell = NSView(frame: frame)
            shell.wantsLayer = true
            shell.layer?.backgroundColor = NSColor.clear.cgColor
            shell.layer?.cornerRadius = Theme.Radius.pastPanel
            shell.layer?.masksToBounds = true
            shell.addSubview(glass)
            contentView = shell
            hasShadow = false
        } else {
            let material = NSVisualEffectView(frame: frame)
            material.autoresizingMask = [.width, .height]
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.addSubview(hosting)
            contentView = material
        }
        installResizeSurface()
    }

    private func installResizeSurface() {
        guard let contentView else { return }
        let surface = PaletteResizeSurface(frame: contentView.bounds)
        surface.autoresizingMask = [.width, .height]
        contentView.addSubview(surface)
        resizeSurface = surface
    }

    func applyVisualStyle(_ visualStyle: PaletteVisualStyle) {
        if #available(macOS 26.0, *), let glass = contentView as? NSGlassEffectView {
            glass.cornerRadius = Self.cornerRadius(for: visualStyle)
        }
    }

    private static func cornerRadius(for visualStyle: PaletteVisualStyle) -> CGFloat {
        visualStyle == .past ? Theme.Radius.pastPanel : Theme.Radius.panel
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class TransparentPaletteHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

/// Owns only the outer edge; the rest of the palette keeps its existing hit testing.
private final class PaletteResizeSurface: NSView {
    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Self(rawValue: 1)
        static let right = Self(rawValue: 2)
        static let bottom = Self(rawValue: 4)
        static let top = Self(rawValue: 8)
    }

    private var tracking: NSTrackingArea?

    private func edges(at point: NSPoint) -> Edges {
        guard bounds.contains(point) else { return [] }
        let horizontal = point.x < 20 || point.x > bounds.width - 20
        let vertical = point.y < 20 || point.y > bounds.height - 20
        let margin: CGFloat = horizontal && vertical ? 20 : 8
        var edges: Edges = []
        if point.x < margin { edges.insert(.left) }
        if point.x > bounds.width - margin { edges.insert(.right) }
        if point.y < margin { edges.insert(.bottom) }
        if point.y > bounds.height - margin { edges.insert(.top) }
        return edges
    }

    func containsResizePoint(_ point: NSPoint) -> Bool {
        !edges(at: convert(point, from: nil)).isEmpty
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let w = bounds.width
        let h = bounds.height
        addCursorRect(NSRect(x: 0, y: 20, width: 8, height: max(h - 40, 0)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: w - 8, y: 20, width: 8, height: max(h - 40, 0)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 20, y: 0, width: max(w - 40, 0), height: 8), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 20, y: h - 8, width: max(w - 40, 0), height: 8), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: 0, width: 20, height: 20), cursor: Self.risingCursor)
        addCursorRect(NSRect(x: w - 20, y: h - 20, width: 20, height: 20), cursor: Self.risingCursor)
        addCursorRect(NSRect(x: 0, y: h - 20, width: 20, height: 20), cursor: Self.fallingCursor)
        addCursorRect(NSRect(x: w - 20, y: 0, width: 20, height: 20), cursor: Self.fallingCursor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        edges(at: convert(point, from: superview)).isEmpty ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func cursor(for edges: Edges) -> NSCursor {
        let horizontal = !edges.intersection([.left, .right]).isEmpty
        let vertical = !edges.intersection([.top, .bottom]).isEmpty
        if horizontal && vertical {
            let rising = edges == [.left, .bottom] || edges == [.right, .top]
            return rising ? Self.risingCursor : Self.fallingCursor
        }
        return horizontal ? .resizeLeftRight : .resizeUpDown
    }

    private static let risingCursor = diagonalCursor("arrow.up.right.and.arrow.down.left")
    private static let fallingCursor = diagonalCursor("arrow.up.left.and.arrow.down.right")

    private static func diagonalCursor(_ symbol: String) -> NSCursor {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return .crosshair
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
    }

    override func cursorUpdate(with event: NSEvent) {
        let edges = edges(at: convert(event.locationInWindow, from: nil))
        if !edges.isEmpty { cursor(for: edges).set() }
    }

    override func mouseMoved(with event: NSEvent) { cursorUpdate(with: event) }
    override func mouseEntered(with event: NSEvent) { cursorUpdate(with: event) }
    override func mouseExited(with event: NSEvent) { window?.invalidateCursorRects(for: self) }

    override func mouseDown(with event: NSEvent) {
        guard let panel = window as? PalettePanel else { return }
        let edges = edges(at: convert(event.locationInWindow, from: nil))
        guard !edges.isEmpty else { return }
        let initial = panel.frame
        let start = panel.convertPoint(toScreen: event.locationInWindow)
        let resizeCursor = cursor(for: edges)
        resizeCursor.push()
        defer {
            NSCursor.pop()
            panel.onUserResizeEnded?()
            panel.invalidateCursorRects(for: self)
        }
        while let next = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = panel.convertPoint(toScreen: next.locationInWindow)
            let dx = point.x - start.x
            let dy = point.y - start.y
            var frame = initial
            if edges.contains(.left) || edges.contains(.right) {
                let proposed = initial.width + (edges.contains(.left) ? -dx : dx)
                frame.size.width = min(max(proposed, panel.minSize.width), panel.maxSize.width)
                if edges.contains(.left) { frame.origin.x = initial.maxX - frame.width }
            }
            if edges.contains(.bottom) || edges.contains(.top) {
                let proposed = initial.height + (edges.contains(.bottom) ? -dy : dy)
                frame.size.height = min(max(proposed, panel.minSize.height), panel.maxSize.height)
                if edges.contains(.bottom) { frame.origin.y = initial.maxY - frame.height }
            }
            panel.setFrame(frame, display: true)
            panel.contentView?.layoutSubtreeIfNeeded()
            resizeCursor.set()
        }
    }
}
