import XCTest

final class ItemQuickGestureTests: XCTestCase {
    @MainActor
    func testQuickSettingsDefaultToDragAndPersistIndependently() throws {
        let suite = "QuickGestureTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.quickGestureMode(for: .link), .drag)
        XCTAssertEqual(settings.quickGestureMode(for: .image), .drag)
        XCTAssertNil(settings.quickGestureMode(for: .text))
        XCTAssertNil(settings.quickGestureMode(for: .code))
        settings.quickLinkGesture = .swipe
        settings.quickImageGesture = .both
        settings.quickLinkEnabled = false
        let restored = AppSettings(defaults: defaults)
        XCTAssertNil(restored.quickGestureMode(for: .link))
        XCTAssertEqual(restored.quickLinkGesture, .swipe)
        XCTAssertEqual(restored.quickGestureMode(for: .image), .both)
        restored.quickLinkEnabled = true
        XCTAssertEqual(restored.quickGestureMode(for: .link), .swipe)
        restored.quickImageEnabled = false
        XCTAssertNil(restored.quickGestureMode(for: .image))
    }

    @MainActor
    func testUnknownSavedGestureFallsBackToDrag() throws {
        let suite = "QuickGestureTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("obsolete", forKey: "quickLinkGesture")
        XCTAssertEqual(AppSettings(defaults: defaults).quickLinkGesture, .drag)
    }

    func testOnlyPhysicalPreciseScrollCanStartQuickAction() {
        XCTAssertNil(ItemQuickGesture.scrollContentDelta(x: 100, y: 0,
            precise: false, hasPhase: true, momentum: false))
        XCTAssertNil(ItemQuickGesture.scrollContentDelta(x: 100, y: 0,
            precise: true, hasPhase: false, momentum: false))
        XCTAssertNil(ItemQuickGesture.scrollContentDelta(x: 100, y: 0,
            precise: true, hasPhase: true, momentum: true))
    }

    func testScrollDirectionMatchesContentInsteadOfFlippedDocumentCoordinates() throws {
        let delta = try XCTUnwrap(ItemQuickGesture.scrollContentDelta(x: 90, y: -90,
            precise: true, hasPhase: true, momentum: false))
        var daycast = ItemQuickGesture(direction: .right, input: .swipe)
        daycast.update(x: delta.x, y: 0)
        XCTAssertEqual(daycast.finish(), .quickAction)
        var past = ItemQuickGesture(direction: .up, input: .swipe)
        past.update(x: 0, y: delta.y)
        XCTAssertEqual(past.finish(), .quickAction)
    }

    func testDragNeedsDirectionAndReleaseThreshold() {
        var gesture = ItemQuickGesture(direction: .right, input: .drag)
        gesture.update(x: 11, y: 0)
        XCTAssertEqual(gesture.intent, .undecided)
        XCTAssertFalse(gesture.moved)
        gesture.update(x: 12, y: 4)
        XCTAssertEqual(gesture.intent, .action)
        gesture.update(x: 63, y: 4)
        XCTAssertFalse(gesture.armed)
        gesture.update(x: 64, y: 4)
        XCTAssertTrue(gesture.armed)
        XCTAssertEqual(gesture.finish(), .quickAction)
        XCTAssertEqual(gesture.finish(), .none)
    }

    func testUpwardPastDragCommits() {
        var gesture = ItemQuickGesture(direction: .up, input: .drag)
        gesture.update(x: 10, y: 80)
        XCTAssertTrue(gesture.armed)
        XCTAssertEqual(gesture.finish(), .quickAction)
    }

    func testReturningBelowThresholdDisarms() {
        var gesture = ItemQuickGesture(direction: .up, input: .drag)
        gesture.update(x: 0, y: 90)
        XCTAssertTrue(gesture.armed)
        gesture.update(x: 0, y: 45)
        XCTAssertFalse(gesture.armed)
        XCTAssertEqual(gesture.finish(), .none)
    }

    func testBrowsingNeverTurnsIntoAnAction() {
        for direction in [ItemQuickGesture.Direction.right, .up] {
            var gesture = ItemQuickGesture(direction: direction, input: .swipe)
            gesture.update(x: direction == .right ? 2 : 20, y: direction == .right ? 20 : 2)
            XCTAssertEqual(gesture.intent, .browsing)
            gesture.update(x: direction == .right ? 150 : 20, y: direction == .right ? 20 : 150)
            XCTAssertFalse(gesture.armed)
            XCTAssertEqual(gesture.finish(), .none)
        }
    }

    func testOppositeDirectionLocksOutAction() {
        var gesture = ItemQuickGesture(direction: .right, input: .drag)
        gesture.update(x: -20, y: 1)
        gesture.update(x: 100, y: 1)
        XCTAssertEqual(gesture.finish(), .none)
    }

    func testDiagonalMotionMustResolveToAnAxis() {
        var gesture = ItemQuickGesture(direction: .right, input: .drag)
        gesture.update(x: 80, y: 70)
        XCTAssertEqual(gesture.intent, .undecided)
        XCTAssertFalse(gesture.armed)
        gesture.update(x: 105, y: 70)
        XCTAssertTrue(gesture.armed)
        gesture.update(x: 105, y: 90)
        XCTAssertFalse(gesture.armed)
    }

    func testSwipeUsesHigherThreshold() {
        var gesture = ItemQuickGesture(direction: .up, input: .swipe)
        gesture.update(x: 0, y: 79)
        XCTAssertFalse(gesture.armed)
        gesture.update(x: 0, y: 80)
        XCTAssertEqual(gesture.finish(), .quickAction)
    }

    func testCancellationCannotBeRearmed() {
        var gesture = ItemQuickGesture(direction: .right, input: .drag)
        gesture.update(x: 100, y: 0)
        gesture.cancel()
        gesture.update(x: 120, y: 0)
        XCTAssertFalse(gesture.armed)
        XCTAssertEqual(gesture.finish(overGroup: true), .none)
    }

    func testGroupDropTakesPriorityOverQuickAction() {
        var gesture = ItemQuickGesture(direction: .up, input: .drag)
        gesture.update(x: 0, y: 100)
        XCTAssertEqual(gesture.finish(overGroup: true), .group)
        XCTAssertEqual(gesture.finish(), .none)
    }

    func testOtherDragDirectionsCanStillReachGroups() {
        var gesture = ItemQuickGesture(direction: .up, input: .drag)
        gesture.update(x: 100, y: 10)
        XCTAssertEqual(gesture.finish(overGroup: true), .group)
        var click = ItemQuickGesture(direction: .up, input: .drag)
        click.update(x: 2, y: 2)
        XCTAssertEqual(click.finish(overGroup: true), .none)
    }

    func testSwipeCannotDropIntoGroup() {
        var gesture = ItemQuickGesture(direction: .up, input: .swipe)
        gesture.update(x: 0, y: 90)
        XCTAssertEqual(gesture.finish(overGroup: true), .quickAction)
    }

    func testInputModesAreIndependent() {
        XCTAssertTrue(ItemGestureMode.drag.allows(.drag))
        XCTAssertFalse(ItemGestureMode.drag.allows(.swipe))
        XCTAssertTrue(ItemGestureMode.swipe.allows(.swipe))
        XCTAssertFalse(ItemGestureMode.swipe.allows(.drag))
        XCTAssertTrue(ItemGestureMode.both.allows(.drag))
        XCTAssertTrue(ItemGestureMode.both.allows(.swipe))
    }
}
