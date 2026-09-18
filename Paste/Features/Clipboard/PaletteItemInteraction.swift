import AppKit
import SwiftUI

/// Weak geometry registrations let a single window event gateway coordinate SwiftUI cards,
/// AppKit rows and pinboard destinations, without installing competing gesture recognizers.
@MainActor
final class PaletteItemRegion: NSObject {
    weak var view: NSView?
    var itemAtPoint: ((NSPoint) -> ClipboardItem?)?
    var acceptDrop: ((String) -> Bool)?
    var enabled = true

    init(view: NSView) { self.view = view }

    func contains(_ point: NSPoint) -> Bool {
        guard enabled, let view, !view.isHiddenOrHasHiddenAncestor else { return false }
        // Modern NSViews need not clip to their bounds: visibleRect can extend into a
        // neighboring card. Both the card's own bounds and its scroll clipping must agree.
        return view.bounds.intersection(view.visibleRect).contains(view.convert(point, from: nil))
    }
}

struct PaletteItemInteractionRegion: NSViewRepresentable {
    var item: ClipboardItem? = nil
    var enabled = true
    var acceptDrop: ((String) -> Bool)? = nil

    func makeNSView(context: Context) -> PaletteItemRegionView { PaletteItemRegionView() }

    func updateNSView(_ view: PaletteItemRegionView, context: Context) {
        view.region.itemAtPoint = { _ in item }
        view.region.enabled = enabled
        view.region.acceptDrop = acceptDrop
    }
}

final class PaletteItemRegionView: NSView {
    lazy var region = PaletteItemRegion(view: self)

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? PalettePanel)?.itemInteractions.register(region)
    }
}

@MainActor
final class PaletteItemInteractionController {
    private let regions = NSHashTable<PaletteItemRegion>.weakObjects()
    private weak var panel: PalettePanel?
    private let direction: ItemQuickGesture.Direction
    private let supportsGroups: Bool
    private let settings: AppSettings
    private var drag: Session?
    private var swipe: Session?
    private var lastClickedID: UUID?
    private var swallowMouseUp = false
    private var swallowMomentum = false
    private let hint = InteractionHint()

    private struct Session {
        let item: ClipboardItem
        let origin: NSPoint
        var gesture: ItemQuickGesture
        var delta = NSPoint.zero
        var isDoubleClick = false
        var permitsQuickAction = true
    }

    init(panel: PalettePanel, style: PaletteVisualStyle, settings: AppSettings? = nil) {
        self.panel = panel
        self.settings = settings ?? AppCore.shared.settings
        direction = style == .daycast ? .right : .up
        supportsGroups = style == .past
    }

    func register(_ region: PaletteItemRegion) { regions.add(region) }

    func cancel() {
        if drag != nil { swallowMouseUp = true }
        drag = nil
        swipe = nil
        lastClickedID = nil
        swallowMomentum = false
        hint.removeFromSuperview()
    }

    /// Returns true only for events owned by this interaction. Normal scroll, right-click,
    /// text editing, and disabled quick-drag behavior keep their existing AppKit routing.
    func handle(_ event: NSEvent) -> Bool {
        guard let panel, let vm = panel.paletteViewModel else { return false }
        if event.type == .leftMouseUp, swallowMouseUp {
            swallowMouseUp = false
            return true
        }
        if event.type == .keyDown, event.keyCode == 53, drag != nil || swipe != nil {
            cancel()
            return true
        }
        guard panel.isVisible, !panel.auxiliaryInputActive, vm.itemInteractionsEnabled else {
            cancel()
            return false
        }
        switch event.type {
        case .leftMouseDown:
            swipe = nil
            hint.removeFromSuperview()
            swallowMouseUp = false
            guard let item = item(at: event.locationInWindow) else {
                lastClickedID = nil
                return false
            }
            let doubleClick = event.clickCount == 2 && lastClickedID == item.id
            lastClickedID = item.id
            let permitsDrag = allows(item, input: .drag)
            guard doubleClick || permitsDrag else { return false }
            drag = Session(item: item, origin: event.locationInWindow,
                           gesture: ItemQuickGesture(direction: direction, input: .drag),
                           isDoubleClick: doubleClick, permitsQuickAction: permitsDrag)
            vm.select(item.id)
            return true
        case .leftMouseDragged:
            guard var session = drag else { return false }
            update(&session, point: event.locationInWindow)
            drag = session
            if session.gesture.moved { lastClickedID = nil }
            showHint(for: session, at: event.locationInWindow)
            return true
        case .leftMouseUp:
            guard var session = drag else { return false }
            update(&session, point: event.locationInWindow)
            drag = nil
            hint.removeFromSuperview()
            let group = supportsGroups ? group(at: event.locationInWindow) : nil
            let outcome = session.gesture.finish(
                insidePanel: insidePanel(event.locationInWindow), overGroup: group != nil)
            if outcome == .group {
                _ = group?.acceptDrop?(session.item.id.uuidString)
            } else if outcome == .quickAction, session.permitsQuickAction {
                vm.performQuickAction(id: session.item.id, input: .drag)
            } else if session.isDoubleClick, !session.gesture.moved,
                      item(at: event.locationInWindow)?.id == session.item.id {
                vm.pasteItem(id: session.item.id)
            }
            return true
        case .scrollWheel:
            return handleScroll(event, vm: vm)
        default:
            return false
        }
    }

    private func handleScroll(_ event: NSEvent, vm: PaletteViewModel) -> Bool {
        // A precise device plus a physical phase is required. Momentum never starts or
        // commits an action, and conventional wheel ticks always remain scrolling.
        if !event.momentumPhase.isEmpty { return swallowMomentum }
        guard drag == nil, let delta = ItemQuickGesture.scrollContentDelta(
            x: event.scrollingDeltaX, y: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas, hasPhase: !event.phase.isEmpty,
            momentum: !event.momentumPhase.isEmpty
        ) else { return false }
        if event.phase.contains(.began) {
            swallowMomentum = false
            swipe = nil
            hint.removeFromSuperview()
            if let item = item(at: event.locationInWindow), allows(item, input: .swipe) {
                swipe = Session(item: item, origin: event.locationInWindow,
                                gesture: ItemQuickGesture(direction: direction, input: .swipe))
            }
        }
        guard var session = swipe else { return false }
        session.delta.x += delta.x
        session.delta.y += delta.y
        session.gesture.update(x: session.delta.x, y: session.delta.y)
        let consumed = session.gesture.intent == .action
        swallowMomentum = consumed
        if event.phase.contains(.cancelled) {
            swipe = nil
            hint.removeFromSuperview()
        } else if event.phase.contains(.ended) {
            swipe = nil
            hint.removeFromSuperview()
            if session.gesture.finish(insidePanel: insidePanel(event.locationInWindow)) == .quickAction {
                vm.performQuickAction(id: session.item.id, input: .swipe)
            }
        } else {
            swipe = session
            if consumed { showHint(for: session, at: session.origin) }
        }
        return consumed
    }

    private func update(_ session: inout Session, point: NSPoint) {
        session.gesture.update(x: point.x - session.origin.x, y: point.y - session.origin.y)
    }

    private func allows(_ item: ClipboardItem, input: ItemQuickGesture.Input) -> Bool {
        settings.quickGestureMode(for: item.kind)?.allows(input) == true
    }

    private func item(at point: NSPoint) -> ClipboardItem? {
        for region in regions.allObjects where region.view?.window === panel && region.contains(point) {
            if let item = region.itemAtPoint?(point) { return item }
        }
        return nil
    }

    private func group(at point: NSPoint) -> PaletteItemRegion? {
        regions.allObjects.first {
            $0.view?.window === panel && $0.acceptDrop != nil && $0.contains(point)
        }
    }

    private func insidePanel(_ point: NSPoint) -> Bool {
        guard let content = panel?.contentView else { return false }
        return content.bounds.contains(content.convert(point, from: nil))
    }

    private func showHint(for session: Session, at point: NSPoint) {
        guard session.gesture.moved, insidePanel(point), let content = panel?.contentView else {
            hint.removeFromSuperview()
            return
        }
        let locale = settings.language.locale
        let label: String
        if supportsGroups, session.gesture.input == .drag, group(at: point) != nil {
            label = String(localized: "Release to Add to Pinboard", locale: locale)
        } else if session.gesture.armed, session.permitsQuickAction {
            label = session.item.kind == .link
                ? String(localized: "Release to Open Link", locale: locale)
                : String(localized: "Release to Pin Image", locale: locale)
        } else {
            label = direction == .right
                ? String(localized: "Drag Right for Quick Action", locale: locale)
                : String(localized: "Drag Up for Quick Action", locale: locale)
        }
        hint.stringValue = label
        hint.sizeToFit()
        let size = NSSize(width: min(hint.frame.width + 20, content.bounds.width), height: 28)
        let position = content.convert(point, from: nil)
        hint.frame = NSRect(
            x: min(max(0, position.x - size.width / 2), content.bounds.width - size.width),
            y: min(max(0, position.y + 20), max(0, content.bounds.height - size.height)),
            width: size.width, height: size.height)
        if hint.superview == nil { content.addSubview(hint) }
    }
}

private final class InteractionHint: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = true
        backgroundColor = .controlBackgroundColor
        textColor = .labelColor
        font = .systemFont(ofSize: 12, weight: .medium)
        alignment = .center
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
