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
