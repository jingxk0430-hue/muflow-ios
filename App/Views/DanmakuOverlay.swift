import DanmakuCore
import MPVUI
import QuartzCore
import SwiftUI
import UIKit

struct DanmakuOverlay: View {
    let model: PlayerModel
    @Environment(\.displayScale) private var displayScale
    @State private var timeline: DanmakuTimeline?
    @State private var anchorPosition = 0.0
    @State private var anchorHost = CACurrentMediaTime()

    private func anchor() {
        anchorPosition = model.position
        anchorHost = CACurrentMediaTime()
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !model.player.state.isPlaying)) { _ in
                Canvas { context, _ in
                    guard model.settings.enabled, let timeline else { return }
                    let elapsed = model.player.state.isPlaying ? max(0, CACurrentMediaTime() - anchorHost) : 0
                    let time = anchorPosition + elapsed * model.player.playbackRate - model.settings.delay
                    for item in timeline.active(at: time) {
                        // Keep cached glyph pixels on physical pixels while scrolling.
                        // Fractional image placement otherwise softens the glyph edge each frame.
                        let point = CGPoint(x: (item.x(at: time) * displayScale).rounded() / displayScale,
                                            y: (item.y * displayScale).rounded() / displayScale)
                        let image = DanmakuTextRenderer.image(item.comment.text, color: item.comment.color,
                                                             fontSize: model.settings.fontSize,
                                                             outline: model.settings.outline, scale: displayScale)
                        context.draw(Image(uiImage: image).interpolation(.none), at: point, anchor: .topLeading)
                    }
                }
                .opacity(model.settings.opacity)
            }
            .task(id: LayoutIdentity(revision: model.commentRevision, settings: model.settings,
                                     width: geometry.size.width, height: geometry.size.height)) {
                timeline = DanmakuTimeline(comments: model.visibleComments,
                                           width: geometry.size.width, height: geometry.size.height,
                                           settings: model.settings) { text, size in
                    Double(DanmakuTextRenderer.size(text, fontSize: size, outline: model.settings.outline).width)
                }
                anchor()
            }
            .onChange(of: model.player.position) { _, _ in
                // Re-anchor to the media clock, including seeks and buffering. No wall-clock drift across pauses.
                anchor()
            }
            .onChange(of: model.player.isPaused) { _, _ in anchor() }
            .onChange(of: model.player.playbackRate) { _, _ in anchor() }
            .onChange(of: model.player.state) { _, _ in anchor() }
            .onAppear { anchor() }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct LayoutIdentity: Equatable {
    let revision: UUID
    let settings: DanmakuSettings
    let width: Double
    let height: Double
}
