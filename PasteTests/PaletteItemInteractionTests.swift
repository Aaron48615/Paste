import AppKit
import SwiftUI
import XCTest

// The test target compiles the actual event adapter, but not the production panel or AppCore.
// This never-visible host records actions without pasting, opening links or creating pins.
typealias PaletteViewModel = InteractionTestModel

final class PalettePanel: NSPanel {
    private var attachedPreviews: [NSWindow] = []
    let paletteViewModel: InteractionTestModel? = InteractionTestModel()
    var auxiliaryInputActive = false
    var itemInteractions: PaletteItemInteractionController!
    override var isVisible: Bool { true }
    override var childWindows: [NSWindow]? { attachedPreviews }
    // Exercise real preview geometry without ever ordering a test window on screen.
    override func addChildWindow(_ childWin: NSWindow, ordered place: NSWindow.OrderingMode) {
        attachedPreviews.append(childWin)
    }
    override func removeChildWindow(_ childWin: NSWindow) {
        attachedPreviews.removeAll { $0 === childWin }
    }
}

@MainActor
final class InteractionTestModel: ObservableObject {
    var itemInteractionsEnabled = true
    @Published var groupDragActive = false
    var selectedID: UUID?
    var pasted: [UUID] = []
    var quickActions: [UUID] = []
    func select(_ id: UUID) { selectedID = id }
    func pasteItem(id: UUID) { pasted.append(id) }
    func performQuickAction(id: UUID, input: ItemQuickGesture.Input) { quickActions.append(id) }
}

final class PaletteItemInteractionTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let suite = "InteractionTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let settings: AppSettings
        let panel: PalettePanel
        let controller: PaletteItemInteractionController
        let model: InteractionTestModel
        var regions: [PaletteItemRegion] = []

        init(style: PaletteVisualStyle = .daycast) {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            settings = AppSettings(defaults: defaults)
            settings.language = .english
            panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
            model = panel.paletteViewModel!
            controller = PaletteItemInteractionController(panel: panel, style: style, settings: settings)
            panel.itemInteractions = controller
        }

        func cleanup() {
            controller.cancel()
            defaults.removePersistentDomain(forName: suite)
        }

        func add(_ item: ClipboardItem, rect: NSRect = NSRect(x: 0, y: 0, width: 150, height: 150)) {
            let view = NSView(frame: rect)
            panel.contentView!.addSubview(view)
            let region = PaletteItemRegion(view: view)
            region.itemAtPoint = { _ in item }
            regions.append(region)
            controller.register(region)
        }

        func addGroup(_ accept: @escaping (String) -> Bool) {
            let view = NSView(frame: NSRect(x: 0, y: 200, width: 150, height: 50))
            panel.contentView!.addSubview(view)
            let region = PaletteItemRegion(view: view)
            region.acceptDrop = accept
            regions.append(region)
            controller.register(region)
        }

        @discardableResult
        func mouse(_ type: NSEvent.EventType, x: CGFloat = 50, y: CGFloat = 50, clicks: Int = 1) -> Bool {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 0)!
            return controller.handle(event)
        }

        @discardableResult
        func scroll(x: CGFloat = 0, y: CGFloat = 0, phase: NSEvent.Phase,
                    momentum: NSEvent.Phase = [], precise: Bool = true) -> Bool {
            let event = TestScrollEvent(x: x, y: y, phase: phase, momentum: momentum, precise: precise)
            return controller.handle(event)
        }
    }

    @MainActor
    func testDoubleClickPastesActualItemOnceForEveryKindAndStyle() {
        let items = [ClipboardItem(text: "text", sourceBundleID: nil),
                     ClipboardItem(text: "https://example.com", sourceBundleID: nil),
                     ClipboardItem(text: "#!/bin/sh\necho hi", sourceBundleID: nil),
                     ClipboardItem(imagePath: "/unused", imageFingerprint: "test", sourceBundleID: nil)]
        for style in [PaletteVisualStyle.daycast, .past] {
            for item in items {
                let fixture = Fixture(style: style)
                defer { fixture.cleanup() }
                fixture.add(item)
                fixture.mouse(.leftMouseDown)
                fixture.mouse(.leftMouseUp)
                fixture.model.selectedID = UUID() // Hover/keyboard selection must not retarget it.
                XCTAssertTrue(fixture.mouse(.leftMouseDown, clicks: 2))
                fixture.mouse(.leftMouseUp, clicks: 2)
                fixture.mouse(.leftMouseUp, clicks: 2)
                XCTAssertEqual(fixture.model.pasted, [item.id])
                XCTAssertTrue(fixture.model.quickActions.isEmpty)
            }
        }
    }

    @MainActor
    func testDifferentItemDoesNotCountAsDoubleClick() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.add(ClipboardItem(text: "one", sourceBundleID: nil))
        fixture.add(ClipboardItem(text: "two", sourceBundleID: nil),
                    rect: NSRect(x: 160, y: 0, width: 150, height: 150))
        fixture.mouse(.leftMouseDown)
        fixture.mouse(.leftMouseUp)
        fixture.mouse(.leftMouseDown, x: 200, clicks: 2)
        fixture.mouse(.leftMouseUp, x: 200, clicks: 2)
        XCTAssertTrue(fixture.model.pasted.isEmpty)
    }

    @MainActor
    func testDragKeepsOriginalItemAndCommitsOnlyOnRelease() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let item = ClipboardItem(text: "https://example.com", sourceBundleID: nil)
        fixture.add(item)
        fixture.mouse(.leftMouseDown)
        fixture.mouse(.leftMouseDragged, x: 130)
        fixture.model.selectedID = UUID()
        XCTAssertTrue(fixture.model.quickActions.isEmpty)
        fixture.mouse(.leftMouseUp, x: 130)
        fixture.mouse(.leftMouseUp, x: 130)
        XCTAssertEqual(fixture.model.quickActions, [item.id])
        XCTAssertTrue(fixture.model.pasted.isEmpty)
    }

    @MainActor
    func testUpwardPastDragRevealsGroupChoicesUntilReleaseOrCancel() {
        for style in [PaletteVisualStyle.past, .daycast] {
            for cancel in [false, true] {
                let fixture = Fixture(style: style)
                defer { fixture.cleanup() }
                fixture.add(ClipboardItem(text: "https://example.com", sourceBundleID: nil))
                fixture.mouse(.leftMouseDown)
                fixture.mouse(.leftMouseDragged, y: 58)
                XCTAssertFalse(fixture.model.groupDragActive)
                fixture.mouse(.leftMouseDragged, y: 70)
                XCTAssertEqual(fixture.model.groupDragActive, style == .past)
                // Moving sideways to choose another group must keep the choices visible.
                fixture.mouse(.leftMouseDragged, x: 200, y: 75)
                XCTAssertEqual(fixture.model.groupDragActive, style == .past)
                if cancel { fixture.controller.cancel() }
                else { fixture.mouse(.leftMouseUp, x: 200, y: 75) }
                XCTAssertFalse(fixture.model.groupDragActive)
            }
        }
    }

    @MainActor
    func testPastDropOnGroupWins() {
        let fixture = Fixture(style: .past)
        defer { fixture.cleanup() }
        let item = ClipboardItem(imagePath: "/unused", imageFingerprint: "test", sourceBundleID: nil)
        fixture.add(item)
        var dropped: [String] = []
        fixture.addGroup { dropped.append($0); return true }
        fixture.mouse(.leftMouseDown)
        fixture.mouse(.leftMouseDragged, y: 220)
        fixture.mouse(.leftMouseUp, y: 220)
        XCTAssertEqual(dropped, [item.id.uuidString])
        XCTAssertTrue(fixture.model.quickActions.isEmpty)
    }

    @MainActor
    func testOutsideReleaseCommitsButCancellationDoesNotAct() {
        for style in [PaletteVisualStyle.daycast, .past] {
            for cancel in [false, true] {
                let fixture = Fixture(style: style)
                defer { fixture.cleanup() }
                let item = ClipboardItem(text: "https://example.com", sourceBundleID: nil)
                fixture.add(item)
                fixture.mouse(.leftMouseDown)
                let x: CGFloat = style == .daycast ? 600 : 50
                let y: CGFloat = style == .past ? 500 : 50
                fixture.mouse(.leftMouseDragged, x: x, y: y)
                if cancel { fixture.controller.cancel() }
                fixture.mouse(.leftMouseUp, x: x, y: y)
                XCTAssertEqual(fixture.model.quickActions, cancel ? [] : [item.id])
                XCTAssertTrue(fixture.model.pasted.isEmpty)
            }
        }
    }

    @MainActor
    func testTextHintFollowsPointerOutsideBothLayouts() throws {
        for style in [PaletteVisualStyle.daycast, .past] {
            let fixture = Fixture(style: style)
            defer { fixture.cleanup() }
            fixture.add(ClipboardItem(text: "https://example.com", sourceBundleID: nil))
            fixture.mouse(.leftMouseDown)
            fixture.mouse(.leftMouseDragged, x: style == .daycast ? 130 : 50,
                          y: style == .past ? 130 : 50)
            let preview = try XCTUnwrap(fixture.panel.childWindows?.first,
                                       "Both layouts must show a detached text hint")
            XCTAssertTrue(descendants(of: preview.contentView).compactMap { $0 as? NSImageView }.isEmpty,
                          "Dragging must show text only, not a card snapshot")
            let firstFrame = preview.frame
            fixture.mouse(.leftMouseDragged, x: style == .daycast ? 600 : 50,
                          y: style == .past ? 600 : 50)
            XCTAssertEqual(preview.frame.origin.x - firstFrame.origin.x, style == .daycast ? 470 : 0,
                           accuracy: 0.01)
            XCTAssertEqual(preview.frame.origin.y - firstFrame.origin.y, style == .past ? 470 : 0,
                           accuracy: 0.01)
            XCTAssertTrue(preview.ignoresMouseEvents)
            XCTAssertFalse(preview.canBecomeKey)
            fixture.controller.cancel()
            XCTAssertTrue(fixture.panel.childWindows?.isEmpty != false)
        }
    }

    @MainActor
    private func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @MainActor
    func testTextHintSurvivesDaycastContentReplacement() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.add(ClipboardItem(text: "https://example.com", sourceBundleID: nil))
        fixture.mouse(.leftMouseDown)
        fixture.mouse(.leftMouseDragged, x: 130)
        let hint = try XCTUnwrap(fixture.panel.childWindows?.first)
        let captions = descendants(of: hint.contentView).compactMap { $0 as? NSTextField }
        XCTAssertTrue(captions.contains { $0.stringValue == "Release to Open Link" })
        fixture.panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        fixture.mouse(.leftMouseDragged, x: 600)
        XCTAssertTrue(fixture.panel.childWindows?.first === hint)
        fixture.mouse(.leftMouseUp, x: 600)
        XCTAssertTrue(fixture.panel.childWindows?.isEmpty != false)
    }

    @MainActor
    func testPastAllItemKindsCanDragIntoGroupsRegardlessOfQuickSettings() {
        let items = [ClipboardItem(text: "plain text", sourceBundleID: nil),
                     ClipboardItem(text: "#!/bin/sh\necho hi", sourceBundleID: nil),
                     ClipboardItem(text: "https://example.com", sourceBundleID: nil),
                     ClipboardItem(imagePath: "/unused", imageFingerprint: "test", sourceBundleID: nil)]
        for enabled in [true, false] {
            for item in items {
                let fixture = Fixture(style: .past)
                defer { fixture.cleanup() }
                fixture.settings.quickLinkEnabled = enabled
                fixture.settings.quickImageEnabled = enabled
                fixture.add(item)
                var dropped: [String] = []
                fixture.addGroup { dropped.append($0); return true }
                XCTAssertTrue(fixture.mouse(.leftMouseDown))
                fixture.mouse(.leftMouseDragged, y: 220)
                fixture.mouse(.leftMouseUp, y: 220)
                XCTAssertEqual(dropped, [item.id.uuidString])
                XCTAssertTrue(fixture.model.quickActions.isEmpty)
            }
        }
    }

    @MainActor
    func testPastHostedGroupReceivesDragAndShowsItsName() throws {
        let fixture = Fixture(style: .past)
        defer { fixture.cleanup() }
        let item = ClipboardItem(text: "plain text", sourceBundleID: nil)
        fixture.add(item)
        var dropped: [String] = []
        let hosting = NSHostingView(rootView: RevealedGroupChoices(model: fixture.model) {
            dropped.append($0)
            return true
        })
        hosting.frame = NSRect(x: 0, y: 200, width: 150, height: 50)
        fixture.panel.contentView!.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        fixture.mouse(.leftMouseDown)
        fixture.mouse(.leftMouseDragged, y: 70)
        hosting.layoutSubtreeIfNeeded()
        fixture.mouse(.leftMouseDragged, y: 220)
        let hint = try XCTUnwrap(fixture.panel.childWindows?.first)
        XCTAssertTrue(descendants(of: hint.contentView).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "Release to Add to “Work”" })
        fixture.mouse(.leftMouseUp, y: 220)
        XCTAssertEqual(dropped, [item.id.uuidString])
        XCTAssertTrue(fixture.model.quickActions.isEmpty)
    }

    @MainActor
    func testDroppingOnGroupPickerWhitespaceCancelsQuickAction() {
        let fixture = Fixture(style: .past)
        defer { fixture.cleanup() }
        fixture.add(ClipboardItem(text: "https://example.com", sourceBundleID: nil))
        let picker = NSView(frame: NSRect(x: 0, y: 200, width: 400, height: 100))
        fixture.panel.contentView!.addSubview(picker)
        let region = PaletteItemRegion(view: picker)
        region.isGroupPicker = true
        fixture.regions.append(region)
        fixture.controller.register(region)
        fixture.mouse(.leftMouseDown)
        fixture.mouse(.leftMouseDragged, y: 220)
        XCTAssertTrue(fixture.model.groupDragActive)
        fixture.mouse(.leftMouseUp, y: 220)
        XCTAssertFalse(fixture.model.groupDragActive)
        XCTAssertTrue(fixture.model.quickActions.isEmpty)
    }

    @MainActor
    func testGroupHighlightClearsWhenLeavingAndCancelling() {
        let fixture = Fixture(style: .past)
        defer { fixture.cleanup() }
        fixture.add(ClipboardItem(text: "plain text", sourceBundleID: nil))
        fixture.addGroup { _ in true }
        var highlights: [Bool] = []
        fixture.regions.last?.onDropTargetChanged = { highlights.append($0) }
        fixture.mouse(.leftMouseDown)
        fixture.mouse(.leftMouseDragged, y: 220)
        fixture.mouse(.leftMouseDragged, x: 200, y: 220)
        fixture.mouse(.leftMouseDragged, y: 220)
        fixture.controller.cancel()
        XCTAssertEqual(highlights, [true, false, true, false])
    }

    @MainActor
    func testHintRendersRoundedBodyWithUnclippedShadowInBothAppearances() throws {
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let hint = ItemGestureHintWindow()
            hint.appearance = NSAppearance(named: appearance)
            hint.update(anchor: .zero, label: "Release to Add to Work", ready: true, detail: "Esc to Cancel")
            let view = try XCTUnwrap(hint.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            hint.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
                bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))!.alphaComponent
            }
            XCTAssertEqual(alpha(0, 0), 0, accuracy: 0.01)
            XCTAssertLessThan(alpha(20, 20), 0.2, "The rounded body must not leave an opaque square corner")
            let shadow = alpha(17, view.bounds.midY)
            XCTAssertGreaterThan(shadow, 0.01, "Shadow must be rendered beyond the body")
            XCTAssertLessThan(shadow, 0.5)
            XCTAssertGreaterThan(alpha(view.bounds.midX, view.bounds.midY), 0.9)
        }
    }

    @MainActor
    func testTextHintStaysWithinDisplayAtScreenEdges() {
        let visible = NSRect(x: -1280, y: 0, width: 1280, height: 800)
        for anchor in [NSPoint(x: -1270, y: 10), NSPoint(x: -10, y: 790)] {
            let frame = ItemGestureHintWindow.frame(anchor: anchor,
                size: NSSize(width: 240, height: 62), visibleFrame: visible)
            XCTAssertTrue(visible.contains(frame))
            XCTAssertFalse(frame.contains(anchor), "The hint must not cover the drop target")
        }
    }

    @MainActor
    func testEscapeCancelsDragAndConsumesRelease() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.add(ClipboardItem(text: "https://example.com", sourceBundleID: nil))
        fixture.mouse(.leftMouseDown)
        fixture.mouse(.leftMouseDragged, x: 130)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: fixture.panel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        XCTAssertTrue(fixture.controller.handle(escape))
        XCTAssertTrue(fixture.mouse(.leftMouseUp, x: 130))
        XCTAssertTrue(fixture.model.quickActions.isEmpty)
        XCTAssertTrue(fixture.model.pasted.isEmpty)
    }

    @MainActor
    func testDoubleClickWorksWithQuickActionsDisabled() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let item = ClipboardItem(text: "https://example.com", sourceBundleID: nil)
        fixture.add(item)
        fixture.settings.quickLinkEnabled = false
        XCTAssertFalse(fixture.mouse(.leftMouseDown))
        fixture.mouse(.leftMouseUp)
        XCTAssertTrue(fixture.mouse(.leftMouseDown, clicks: 2))
        fixture.mouse(.leftMouseUp, clicks: 2)
        XCTAssertEqual(fixture.model.pasted, [item.id])
    }

    @MainActor
    func testDisabledGesturesAndModalEditingLeaveNativeEventsAlone() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.add(ClipboardItem(text: "https://example.com", sourceBundleID: nil))
        fixture.settings.quickLinkEnabled = false
        XCTAssertFalse(fixture.mouse(.leftMouseDown))
        XCTAssertFalse(fixture.mouse(.leftMouseDragged, x: 130))
        XCTAssertFalse(fixture.mouse(.leftMouseUp, x: 130))
        fixture.settings.quickLinkEnabled = true
        fixture.model.itemInteractionsEnabled = false
        XCTAssertFalse(fixture.mouse(.leftMouseDown, clicks: 2))
        fixture.model.itemInteractionsEnabled = true
        fixture.panel.auxiliaryInputActive = true
        XCTAssertFalse(fixture.mouse(.leftMouseDown, clicks: 2))
        XCTAssertTrue(fixture.model.quickActions.isEmpty)
        XCTAssertTrue(fixture.model.pasted.isEmpty)
    }

    @MainActor
    func testPhysicalSwipeCommitsOnceAndMomentumDoesNotAct() {
        for style in [PaletteVisualStyle.daycast, .past] {
            let fixture = Fixture(style: style)
            defer { fixture.cleanup() }
            let item = ClipboardItem(text: "https://example.com", sourceBundleID: nil)
            fixture.add(item)
            fixture.settings.quickLinkGesture = .swipe
            fixture.scroll(phase: .began)
            fixture.scroll(x: style == .daycast ? 90 : 0, y: style == .past ? -90 : 0, phase: .changed)
            XCTAssertTrue(fixture.model.quickActions.isEmpty)
            fixture.model.selectedID = UUID()
            fixture.scroll(phase: .ended)
            fixture.scroll(x: 100, y: -100, phase: [], momentum: .began)
            fixture.scroll(phase: .ended)
            XCTAssertEqual(fixture.model.quickActions, [item.id])
        }
    }

    @MainActor
    func testBrowsingWheelAndCancelledSwipeNeverAct() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.add(ClipboardItem(text: "https://example.com", sourceBundleID: nil))
        fixture.settings.quickLinkGesture = .both
        fixture.scroll(phase: .began)
        XCTAssertFalse(fixture.scroll(y: 20, phase: .changed))
        XCTAssertFalse(fixture.scroll(x: 150, phase: .changed))
        fixture.scroll(phase: .ended)
        fixture.scroll(x: 150, phase: .began, precise: false)
        fixture.scroll(phase: .ended)
        fixture.scroll(phase: .began)
        fixture.scroll(x: 150, phase: .changed)
        fixture.scroll(phase: .cancelled)
        fixture.scroll(phase: .ended)
        XCTAssertTrue(fixture.model.quickActions.isEmpty)
    }
}

private final class TestScrollEvent: NSEvent {
    private let x: CGFloat
    private let y: CGFloat
    private let eventPhase: NSEvent.Phase
    private let eventMomentum: NSEvent.Phase
    private let precise: Bool
    init(x: CGFloat, y: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase, precise: Bool) {
        self.x = x
        self.y = y
        eventPhase = phase
        eventMomentum = momentum
        self.precise = precise
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var scrollingDeltaX: CGFloat { x }
    override var scrollingDeltaY: CGFloat { y }
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { eventMomentum }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var locationInWindow: NSPoint { NSPoint(x: 50, y: 50) }
}

private struct RevealedGroupChoices: View {
    @ObservedObject var model: InteractionTestModel
    let acceptDrop: (String) -> Bool

    var body: some View {
        Group {
            if model.groupDragActive {
                ScrollView(.horizontal) {
                    HStack {
                        Text("Work").frame(width: 150, height: 50)
                            .modifier(PaletteGroupDropTarget(title: "Work", enabled: true, acceptDrop: acceptDrop))
                    }
                }.scrollIndicators(.hidden)
            } else {
                Color.clear
            }
        }
    }
}
