import Foundation
import Observation

/// What the floating button shows that is not the dictation itself: where it is, whether the
/// pointer is over it, whether it is being dragged and whether the box is open.
@MainActor
@Observable
final class UniConnectDictationBubbleState {
    var layout: UniConnectDictationBubbleLayout
    var hovering = false
    var dragging = false
    var boxOpen = false

    init(layout: UniConnectDictationBubbleLayout) {
        self.layout = layout
    }
}
