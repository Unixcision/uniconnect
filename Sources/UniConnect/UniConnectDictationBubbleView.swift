import SwiftUI

/// The floating button: a round microphone, red with a timer while recording and a spinner while
/// Whisper reads; or, tucked into the edge, a pill of the same colour.
struct UniConnectDictationBubbleView: View {
    let model: UniConnectDictationModel
    let state: UniConnectDictationBubbleState

    var body: some View {
        if state.layout.docked {
            pill
        } else {
            bubble
        }
    }

    private var tint: Color {
        if model.isRecording { return .red }
        if model.isTranscribing { return .orange }
        return .accentColor
    }

    private var bubble: some View {
        ZStack {
            Circle().fill(tint.gradient)
            if model.isRecording {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    VStack(spacing: 1) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text(UniConnectDictationClock(seconds: model.meter().seconds).text)
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    }
                }
            } else if model.isTranscribing {
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        .frame(width: UniConnectDictationBubbleLayout.bubbleDiameter, height: UniConnectDictationBubbleLayout.bubbleDiameter)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
        .scaleEffect(state.hovering && !state.dragging ? 1.08 : 1)
        .animation(.easeOut(duration: 0.12), value: state.hovering)
        // The window is larger than the button: growing on hover and the shadow fit inside it.
        .frame(
            width: UniConnectDictationBubbleLayout.bubbleDiameter + 2 * UniConnectDictationBubbleLayout.bubblePadding,
            height: UniConnectDictationBubbleLayout.bubbleDiameter + 2 * UniConnectDictationBubbleLayout.bubblePadding
        )
    }

    private var pill: some View {
        let wide = state.hovering || model.isRecording
        return HStack(spacing: 0) {
            if state.layout.edge == .right { Spacer(minLength: 0) }
            Capsule()
                .fill(tint.opacity(wide ? 0.95 : 0.7))
                .frame(width: wide ? 10 : 6, height: wide ? 60 : 46)
                .padding(.horizontal, 2)
            if state.layout.edge == .left { Spacer(minLength: 0) }
        }
        .frame(width: UniConnectDictationBubbleLayout.pillWindowSize.width, height: UniConnectDictationBubbleLayout.pillWindowSize.height)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: wide)
    }
}
