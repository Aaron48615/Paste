import AppKit
import XCTest

// The test target compiles the actual event adapter, but not the production panel or AppCore.
// This never-visible host records actions without pasting, opening links or creating pins.
typealias PaletteViewModel = InteractionTestModel

final class PalettePanel: NSPanel {
    let paletteViewModel: InteractionTestModel? = InteractionTestModel()
    var auxiliaryInputActive = false
    lazy var itemInteractions = PaletteItemInteractionController(panel: self, style: .daycast)
    override var isVisible: Bool { true }
}

@MainActor
final class InteractionTestModel {
    var itemInteractionsEnabled = true
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
            panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
            model = panel.paletteViewModel!
            controller = PaletteItemInteractionController(panel: panel, style: style, settings: settings)
        }

        func cleanup() { defaults.removePersistentDomain(forName: suite) }

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
    func testOutsideReleaseAndCancellationDoNotAct() {
        for cancel in [false, true] {
            let fixture = Fixture()
            defer { fixture.cleanup() }
            fixture.add(ClipboardItem(text: "https://example.com", sourceBundleID: nil))
            fixture.mouse(.leftMouseDown)
            fixture.mouse(.leftMouseDragged, x: 130)
            if cancel { fixture.controller.cancel() }
            fixture.mouse(.leftMouseUp, x: cancel ? 130 : 600)
            XCTAssertTrue(fixture.model.quickActions.isEmpty)
            XCTAssertTrue(fixture.model.pasted.isEmpty)
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
