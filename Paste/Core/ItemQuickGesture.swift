import Foundation

enum ItemGestureMode: String, CaseIterable, Identifiable {
    case drag, swipe, both

    var id: String { rawValue }
    var title: String {
        switch self {
        case .drag: "Hold and Drag"
        case .swipe: "Two-Finger Swipe"
        case .both: "Drag and Swipe"
        }
    }

    func allows(_ input: ItemQuickGesture.Input) -> Bool {
        self == .both || (self == .drag && input == .drag) || (self == .swipe && input == .swipe)
    }
}

/// Coordinates describe content movement, with positive Y pointing up, in points.
/// Input adapters own event phases; this value type never performs an action itself.
struct ItemQuickGesture {
    enum Direction { case right, up }
    enum Input { case drag, swipe }
    enum Intent { case undecided, action, browsing }
    enum Outcome: Equatable { case none, quickAction, group }

    let direction: Direction
    let input: Input
    private(set) var intent: Intent = .undecided
    private(set) var moved = false
    private(set) var armed = false
    private(set) var finished = false

    /// AppKit deltas already respect natural scrolling. Its scroll Y is expressed in
    /// flipped document coordinates; convert to the window/content coordinates used by drags.
    static func scrollContentDelta(
        x: CGFloat, y: CGFloat, precise: Bool, hasPhase: Bool, momentum: Bool
    ) -> CGPoint? {
        guard precise, hasPhase, !momentum else { return nil }
        return CGPoint(x: x, y: -y)
    }

    mutating func update(x: CGFloat, y: CGFloat) {
        guard !finished else { return }
        let along = direction == .right ? x : y
        let across = abs(direction == .right ? y : x)
        if max(abs(x), abs(y)) >= 12 { moved = true }
        if intent == .undecided, moved {
            if along > 0, along >= across * 1.5 {
                intent = .action
            } else if across >= abs(along) * 1.5 || along <= -12 {
                intent = .browsing
            }
        }
        armed = intent == .action && along >= (input == .drag ? 64 : 80)
            && along >= across * 1.5
    }

    mutating func finish(overGroup: Bool = false) -> Outcome {
        guard !finished else { return .none }
        finished = true
        defer { armed = false }
        if input == .drag, moved, overGroup { return .group }
        return armed ? .quickAction : .none
    }

    mutating func cancel() {
        finished = true
        armed = false
    }
}
