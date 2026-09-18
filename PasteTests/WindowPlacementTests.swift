import CoreGraphics
import XCTest

final class WindowPlacementTests: XCTestCase {
    func testPastMovesAboveDifferentBottomDockSizes() {
        for dockHeight in [CGFloat(60), 120, 180] {
            let visible = NSRect(x: 0, y: dockHeight, width: 1440, height: 876 - dockHeight)
            let result = WindowPlacement.pastFrame(visibleFrame: visible, preferredHeight: 328)
            XCTAssertEqual(result, NSRect(x: 8, y: dockHeight + 8, width: 1424, height: 328))
        }
    }

    func testPastRespectsLeftAndRightDocks() {
        let leftDock = NSRect(x: 90, y: 0, width: 1350, height: 876)
        let rightDock = NSRect(x: 0, y: 0, width: 1350, height: 876)
        XCTAssertEqual(WindowPlacement.pastFrame(visibleFrame: leftDock, preferredHeight: 328),
                       NSRect(x: 98, y: 8, width: 1334, height: 328))
        XCTAssertEqual(WindowPlacement.pastFrame(visibleFrame: rightDock, preferredHeight: 328),
                       NSRect(x: 8, y: 8, width: 1334, height: 328))
    }

    func testPastUsesReportedFrameWithAutoHiddenDock() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 876)
        XCTAssertEqual(WindowPlacement.pastFrame(visibleFrame: visible, preferredHeight: 328),
                       NSRect(x: 8, y: 8, width: 1424, height: 328))
    }

    func testPastFitsSmallSecondaryScreenWithNegativeOrigin() {
        let visible = NSRect(x: -1024, y: -300, width: 1024, height: 300)
        XCTAssertEqual(WindowPlacement.pastFrame(visibleFrame: visible, preferredHeight: 328),
                       NSRect(x: -1016, y: -292, width: 1008, height: 284))
    }

    func testPastRestoresCustomWidthCenteredAboveDock() {
        let visible = NSRect(x: -1440, y: 90, width: 1440, height: 810)
        let result = WindowPlacement.pastFrame(
            visibleFrame: visible, preferredHeight: 400, preferredWidth: 800)
        XCTAssertEqual(result, NSRect(x: -1120, y: 98, width: 800, height: 400))
    }

    func testPastCustomSizeFitsSmallDisplay() {
        let visible = NSRect(x: -1024, y: -300, width: 1024, height: 300)
        XCTAssertEqual(WindowPlacement.pastFrame(
            visibleFrame: visible, preferredHeight: 600, preferredWidth: 1500),
            visible.insetBy(dx: 8, dy: 8))
    }

    func testPaletteSizesPersistIndependentlyAcrossStoreInstances() throws {
        let suite = "WindowPlacementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PaletteSizeStore(defaults: defaults)
        XCTAssertNil(store.load(style: "daycast"))
        XCTAssertNil(store.load(style: "past"))
        store.save(CGSize(width: 450, height: 550), style: "daycast")
        store.save(CGSize(width: 900, height: 400), style: "past")
        let restored = PaletteSizeStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(restored.load(style: "daycast"), CGSize(width: 450, height: 550))
        XCTAssertEqual(restored.load(style: "past"), CGSize(width: 900, height: 400))
    }

    func testInvalidSizesAreIgnored() throws {
        let suite = "WindowPlacementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PaletteSizeStore(defaults: defaults)
        for value in ["garbage", "{}", "{\"width\":-1,\"height\":400}",
                      "{\"width\":400,\"height\":0}", "{\"width\":1e999,\"height\":400}"] {
            defaults.set(Data(value.utf8), forKey: "paletteSize.daycast")
            XCTAssertNil(store.load(style: "daycast"))
        }
        let valid = CGSize(width: 750, height: 475)
        store.save(valid, style: "daycast")
        store.save(CGSize(width: CGFloat.nan, height: 400), style: "daycast")
        store.save(CGSize(width: 400, height: -1), style: "daycast")
        XCTAssertEqual(store.load(style: "daycast"), valid)
    }

    func testScreenClampingDoesNotOverwritePreferredSize() throws {
        let suite = "WindowPlacementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PaletteSizeStore(defaults: defaults)
        let preferred = CGSize(width: 1400, height: 800)
        store.save(preferred, style: "past")
        let small = NSRect(x: 0, y: 0, width: 1024, height: 600)
        let saved = try XCTUnwrap(store.load(style: "past"))
        XCTAssertEqual(WindowPlacement.pastFrame(visibleFrame: small,
            preferredHeight: saved.height, preferredWidth: saved.width), small.insetBy(dx: 8, dy: 8))
        XCTAssertEqual(store.load(style: "past"), preferred)
        let large = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(WindowPlacement.pastFrame(visibleFrame: large,
            preferredHeight: saved.height, preferredWidth: saved.width).size, preferred)
    }

    func testSplitDefaultsAndSavedRatios() {
        XCTAssertEqual(DaycastSplitLayout.listLength(total: 750, ratio: 0, compact: false), 290)
        XCTAssertEqual(DaycastSplitLayout.listLength(total: 400, ratio: 0, compact: true), 391 * 0.45)
        XCTAssertEqual(DaycastSplitLayout.listLength(total: 1009, ratio: 0.6, compact: false), 600)
        XCTAssertEqual(DaycastSplitLayout.listLength(total: 1009, ratio: .nan, compact: false), 290)
    }

    func testSplitDragKeepsBothPanesUsable() {
        XCTAssertEqual(DaycastSplitLayout.constrainedLength(-100, total: 750, compact: false), 220)
        XCTAssertEqual(DaycastSplitLayout.constrainedLength(900, total: 750, compact: false), 481)
        XCTAssertEqual(DaycastSplitLayout.constrainedLength(-100, total: 400, compact: true), 120)
        XCTAssertEqual(DaycastSplitLayout.constrainedLength(900, total: 400, compact: true), 251)
    }

    func testSplitRatioRoundTripsAndSurvivesTemporaryClamping() {
        let ratio = DaycastSplitLayout.ratio(for: 500, total: 1009, compact: false)
        XCTAssertEqual(ratio, 0.5)
        XCTAssertEqual(DaycastSplitLayout.listLength(total: 509, ratio: ratio, compact: false), 240)
        XCTAssertEqual(DaycastSplitLayout.listLength(total: 1009, ratio: ratio, compact: false), 500)
        let vertical = DaycastSplitLayout.ratio(for: 160, total: 409, compact: true)
        XCTAssertEqual(DaycastSplitLayout.listLength(total: 409, ratio: vertical, compact: true), 160)
    }

    func testSplitFitsEvenBelowMinimumAvailableSpace() {
        for compact in [true, false] {
            for total in [CGFloat(0), 9, 50, 200] {
                let available = DaycastSplitLayout.availableLength(total)
                let length = DaycastSplitLayout.listLength(total: total, ratio: 0.8, compact: compact)
                XCTAssertGreaterThanOrEqual(length, 0)
                XCTAssertLessThanOrEqual(length, available)
                XCTAssertTrue(DaycastSplitLayout.ratio(for: length, total: total, compact: compact).isFinite)
            }
        }
    }

    func testSettingsHeightIncludesScreenMarginAndAbsoluteCap() {
        XCTAssertEqual(WindowPlacement.settingsHeight(visibleHeight: 1000), 720)
        XCTAssertEqual(WindowPlacement.settingsHeight(visibleHeight: 650), 618)
        XCTAssertEqual(WindowPlacement.settingsHeight(visibleHeight: 32), 1)
    }

    func testRestoredWindowStaysAboveDock() {
        let visible = NSRect(x: 0, y: 90, width: 1440, height: 786)
        let frame = NSRect(x: 200, y: 0, width: 480, height: 600)
        let result = WindowPlacement.clamp(frame, to: visible.insetBy(dx: 16, dy: 16))
        XCTAssertEqual(result.origin, NSPoint(x: 200, y: 106))
        XCTAssertEqual(result.size, frame.size)
    }

    func testDisconnectedDisplayPositionFitsSmallerScreen() {
        let bounds = NSRect(x: 16, y: 80, width: 992, height: 600)
        let result = WindowPlacement.clamp(
            NSRect(x: 2400, y: -500, width: 1400, height: 800), to: bounds)
        XCTAssertEqual(result, bounds)
    }

    func testSecondaryDisplayWithNegativeOrigin() {
        let bounds = NSRect(x: -1904, y: 40, width: 1888, height: 1000)
        let frame = NSRect(x: -1700, y: 120, width: 800, height: 500)
        XCTAssertEqual(WindowPlacement.clamp(frame, to: bounds), frame)
    }
}
