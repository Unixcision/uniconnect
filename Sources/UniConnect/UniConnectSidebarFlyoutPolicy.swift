import Foundation

/// Pure interaction reducer for the one-per-window compact rail flyout.
struct UniConnectSidebarFlyoutPolicy {
    static let initialHoverDelayMilliseconds = 260
    static let closeDelayMilliseconds = 140

    enum Event: Equatable {
        case pointerEntered(UUID)
        case pointerExited(UUID)
        case focusChanged(UUID, isFocused: Bool)
        case corridorChanged(isInside: Bool)
        case showDelayElapsed(UUID)
        case closeDelayElapsed
        case sourceRemoved(UUID)
        case escape
    }

    enum Effect: Equatable {
        case none
        case scheduleShow(UUID, milliseconds: Int)
        case showNow(UUID)
        case scheduleHide(milliseconds: Int)
        case hideNow
        case cancelScheduledHide
    }

    private(set) var visibleSourceID: UUID?
    private(set) var hoveredSourceID: UUID?
    private(set) var focusedSourceID: UUID?
    private(set) var isInsideCorridor = false

    mutating func reduce(_ event: Event) -> Effect {
        switch event {
        case .pointerEntered(let id):
            hoveredSourceID = id
            if visibleSourceID != nil {
                visibleSourceID = id
                return .showNow(id)
            }
            return .scheduleShow(id, milliseconds: Self.initialHoverDelayMilliseconds)

        case .pointerExited(let id):
            if hoveredSourceID == id {
                hoveredSourceID = nil
            }
            if let focusedSourceID, visibleSourceID != focusedSourceID {
                visibleSourceID = focusedSourceID
                return .showNow(focusedSourceID)
            }
            return shouldRemainVisible
                ? .none
                : .scheduleHide(milliseconds: Self.closeDelayMilliseconds)

        case .focusChanged(let id, let isFocused):
            if isFocused {
                focusedSourceID = id
                visibleSourceID = id
                return .showNow(id)
            }
            if focusedSourceID == id {
                focusedSourceID = nil
            }
            if let hoveredSourceID {
                visibleSourceID = hoveredSourceID
                return .showNow(hoveredSourceID)
            }
            return shouldRemainVisible
                ? .none
                : .scheduleHide(milliseconds: Self.closeDelayMilliseconds)

        case .corridorChanged(let isInside):
            isInsideCorridor = isInside
            return isInside
                ? .cancelScheduledHide
                : (shouldRemainVisible ? .none : .scheduleHide(milliseconds: Self.closeDelayMilliseconds))

        case .showDelayElapsed(let id):
            guard hoveredSourceID == id || focusedSourceID == id else { return .none }
            visibleSourceID = id
            return .showNow(id)

        case .closeDelayElapsed:
            guard !shouldRemainVisible else { return .none }
            visibleSourceID = nil
            return .hideNow

        case .sourceRemoved(let id):
            if hoveredSourceID == id { hoveredSourceID = nil }
            if focusedSourceID == id { focusedSourceID = nil }
            guard visibleSourceID == id else { return .none }
            visibleSourceID = nil
            isInsideCorridor = false
            return .hideNow

        case .escape:
            visibleSourceID = nil
            hoveredSourceID = nil
            focusedSourceID = nil
            isInsideCorridor = false
            return .hideNow
        }
    }

    private var shouldRemainVisible: Bool {
        hoveredSourceID != nil || focusedSourceID != nil || isInsideCorridor
    }
}
