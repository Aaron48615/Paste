import AppKit
import SwiftUI

/// Weak geometry registrations let a single window event gateway coordinate SwiftUI cards,
/// AppKit rows and pinboard destinations, without installing competing gesture recognizers.
@MainActor
final class PaletteItemRegion: NSObject {
    weak var view: NSView?
    var itemAtPoint: ((NSPoint) -> ClipboardItem?)?
    var acceptDrop: ((String) -> Bool)?
    var dropTitle: String?
    var isGroupPicker = false
    var onDropTargetChanged: ((Bool) -> Void)?
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
    var dropTitle: String? = nil
    var isGroupPicker = false
    var onDropTargetChanged: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> PaletteItemRegionView { PaletteItemRegionView() }

    func updateNSView(_ view: PaletteItemRegionView, context: Context) {
        view.region.itemAtPoint = { _ in item }
        view.region.enabled = enabled
        view.region.acceptDrop = acceptDrop
        view.region.isGroupPicker = isGroupPicker
        view.region.dropTitle = dropTitle
        view.region.onDropTargetChanged = onDropTargetChanged
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

/// One destination handles both native drops and the palette's direct drag gesture. Its
/// highlight and caption therefore agree for links, images, code and plain text alike.
struct PaletteGroupDropTarget: ViewModifier {
    let title: String
    let enabled: Bool
    let acceptDrop: (String) -> Bool
    @State private var directTargeted = false
    @State private var nativeTargeted = false
    private var isTargeted: Bool { enabled && (directTargeted || nativeTargeted) }

    func body(content: Content) -> some View {
        content
            .background(isTargeted ? Color.accentColor.opacity(0.12) : .clear, in: Capsule())
            .overlay {
                if isTargeted {
                    Capsule().strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: String.self) { values, _ in
                guard enabled, let value = values.first else { return false }
                return acceptDrop(value)
            } isTargeted: { nativeTargeted = $0 }
            .background(PaletteItemInteractionRegion(
                enabled: enabled, acceptDrop: acceptDrop, dropTitle: title,
                onDropTargetChanged: { directTargeted = $0 }
            ))
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
    private var hintWindow: ItemGestureHintWindow?
    private weak var dropTarget: PaletteItemRegion?

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
        panel?.paletteViewModel?.groupDragActive = false
        swipe = nil
        lastClickedID = nil
        swallowMomentum = false
        dismissHint()
        updateDropTarget(nil)
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
            vm.groupDragActive = false
            swipe = nil
            dismissHint()
            updateDropTarget(nil)
            swallowMouseUp = false
            guard let item = item(at: event.locationInWindow) else {
                lastClickedID = nil
                return false
            }
            let doubleClick = event.clickCount == 2 && lastClickedID == item.id
            lastClickedID = item.id
            let permitsDrag = allows(item, input: .drag)
            guard doubleClick || permitsDrag || supportsGroups else { return false }
            drag = Session(item: item, origin: event.locationInWindow,
                           gesture: ItemQuickGesture(direction: direction, input: .drag),
                           isDoubleClick: doubleClick, permitsQuickAction: permitsDrag)
            vm.select(item.id)
            return true
        case .leftMouseDragged:
            guard var session = drag else { return false }
            update(&session, point: event.locationInWindow)
            drag = session
            let dx = event.locationInWindow.x - session.origin.x
            let dy = event.locationInWindow.y - session.origin.y
            if supportsGroups, !vm.groupDragActive, dy >= 12, dy >= abs(dx) * 1.5 {
                vm.groupDragActive = true
            }
            if session.gesture.moved { lastClickedID = nil }
            updateDropTarget(session.gesture.moved && supportsGroups ? group(at: event.locationInWindow) : nil)
            showHint(for: session, at: event.locationInWindow)
            return true
        case .leftMouseUp:
            guard var session = drag else { return false }
            update(&session, point: event.locationInWindow)
            drag = nil
            dismissHint()
            let group = supportsGroups ? group(at: event.locationInWindow) : nil
            let overPicker = isOverGroupPicker(event.locationInWindow)
            vm.groupDragActive = false
            updateDropTarget(nil)
            let outcome = session.gesture.finish(overGroup: group != nil)
            if outcome == .group {
                _ = group?.acceptDrop?(session.item.id.uuidString)
            } else if outcome == .quickAction, session.permitsQuickAction, !overPicker {
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
            dismissHint()
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
            dismissHint()
        } else if event.phase.contains(.ended) {
            swipe = nil
            dismissHint()
            if session.gesture.finish() == .quickAction {
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

    private func isOverGroupPicker(_ point: NSPoint) -> Bool {
        regions.allObjects.contains {
            $0.isGroupPicker && $0.view?.window === panel && $0.contains(point)
        }
    }

    private func updateDropTarget(_ target: PaletteItemRegion?) {
        guard dropTarget !== target else { return }
        dropTarget?.onDropTargetChanged?(false)
        dropTarget = target
        target?.onDropTargetChanged?(true)
    }

    private func showHint(for session: Session, at point: NSPoint) {
        guard session.gesture.moved, let panel else { return }
        let locale = settings.language.locale
        let label: String
        let ready: Bool
        if let target = dropTarget, session.gesture.input == .drag {
            if let title = target.dropTitle {
                label = String(format: String(localized: "Release to Add to “%@”", locale: locale), title)
            } else {
                label = String(localized: "Release to Add to Pinboard", locale: locale)
            }
            ready = true
        } else if session.gesture.input == .drag, isOverGroupPicker(point) {
            label = String(localized: "Drag to Choose a Pinboard", locale: locale)
            ready = false
        } else if session.gesture.armed, session.permitsQuickAction {
            label = session.item.kind == .link
                ? String(localized: "Release to Open Link", locale: locale)
                : String(localized: "Release to Pin Image", locale: locale)
            ready = true
        } else if supportsGroups, session.gesture.input == .drag,
                  regions.allObjects.contains(where: { $0.enabled && $0.view?.window === panel && $0.acceptDrop != nil }),
                  !session.permitsQuickAction || session.gesture.intent == .browsing {
            label = String(localized: "Drag to a Pinboard Above", locale: locale)
            ready = false
        } else if session.gesture.intent == .browsing || !session.permitsQuickAction {
            label = String(localized: "Release to Cancel", locale: locale)
            ready = false
        } else {
            label = direction == .right
                ? String(localized: "Drag Right for Quick Action", locale: locale)
                : String(localized: "Drag Up for Quick Action", locale: locale)
            ready = false
        }
        let isNew = hintWindow == nil
        if isNew { hintWindow = ItemGestureHintWindow() }
        guard let hintWindow else { return }
        hintWindow.appearance = panel.effectiveAppearance
        let screenPoint = panel.convertPoint(toScreen: point)
        hintWindow.update(anchor: screenPoint, label: label, ready: ready,
                          detail: String(localized: "Esc to Cancel", locale: locale))
        if isNew { panel.addChildWindow(hintWindow, ordered: .above) }
    }

    private func dismissHint() {
        guard let hintWindow else { return }
        panel?.removeChildWindow(hintWindow)
        hintWindow.orderOut(nil)
        self.hintWindow = nil
    }
}

/// Both palette layouts use the same small, mouse-transparent text HUD. Keeping it outside
/// the hosting view prevents SwiftUI relayout and panel clipping from swallowing the hint.
final class ItemGestureHintWindow: NSPanel {
    private let shell = ItemGestureHintSurface()
    private let material = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let indicator = NSView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 220, height: 62),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = ItemGestureHintSurface.radius
        material.layer?.masksToBounds = true
        material.layer?.borderWidth = 0.5
        contentView = shell
        shell.addSubview(material)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 3
        material.addSubview(indicator)
        material.addSubview(titleLabel)
        material.addSubview(detailLabel)
    }

    func update(anchor: NSPoint, label: String, ready: Bool, detail: String) {
        titleLabel.stringValue = label
        detailLabel.stringValue = detail
        titleLabel.sizeToFit()
        detailLabel.sizeToFit()
        let width = min(360, max(180, max(titleLabel.frame.width, detailLabel.frame.width) + 50))
        let inset = ItemGestureHintSurface.inset
        let size = NSSize(width: width + inset * 2, height: 62 + inset * 2)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) }
        setFrame(Self.frame(anchor: anchor, size: size, visibleFrame: screen?.visibleFrame), display: false)
        material.frame = NSRect(x: inset, y: inset, width: width, height: 62)
        // A layer corner radius alone does not clip the effect's backdrop on every macOS
        // version. Mask the visual effect itself, including its compositor-owned surface.
        material.maskImage = NSImage(size: material.bounds.size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: ItemGestureHintSurface.radius,
                         yRadius: ItemGestureHintSurface.radius).fill()
            return true
        }
        shell.needsDisplay = true
        indicator.frame = NSRect(x: 14, y: 36, width: 6, height: 6)
        titleLabel.frame = NSRect(x: 29, y: 30, width: width - 43, height: 18)
        detailLabel.frame = NSRect(x: 29, y: 13, width: width - 43, height: 15)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            indicator.layer?.backgroundColor = (ready ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
            material.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        }
    }

    static func frame(anchor: NSPoint, size: NSSize, visibleFrame: NSRect?) -> NSRect {
        var origin = NSPoint(x: anchor.x + 18, y: anchor.y + 18)
        if let visibleFrame {
            if origin.x + size.width > visibleFrame.maxX { origin.x = anchor.x - size.width - 18 }
            if origin.y + size.height > visibleFrame.maxY { origin.y = anchor.y - size.height - 18 }
            origin.x = max(visibleFrame.minX, min(origin.x, visibleFrame.maxX - size.width))
            origin.y = max(visibleFrame.minY, min(origin.y, visibleFrame.maxY - size.height))
        }
        return NSRect(origin: origin, size: size)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Draw the shadow inside a transparent margin, independently of the clipped backdrop.
/// This avoids both rectangular WindowServer shadows and shadows cut off by the HUD mask.
private final class ItemGestureHintSurface: NSView {
    static let inset: CGFloat = 20
    static let radius: CGFloat = 14
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: Self.inset, dy: Self.inset),
                     xRadius: Self.radius, yRadius: Self.radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
