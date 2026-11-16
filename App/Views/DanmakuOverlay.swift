import DanmakuCore
import MPVUI
import QuartzCore
import SwiftUI
import UIKit

struct DanmakuOverlay: View {
    let model: PlayerModel
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
                    let font = Font.system(size: model.settings.fontSize, weight: .bold)
                    for item in timeline.active(at: time) {
                        let color = Color(red: Double((item.comment.color >> 16) & 255) / 255,
                                          green: Double((item.comment.color >> 8) & 255) / 255,
                                          blue: Double(item.comment.color & 255) / 255)
                        let point = CGPoint(x: item.x(at: time), y: item.y)
                        let shadow = context.resolve(Text(item.comment.text).font(font).foregroundStyle(.black))
                        let outline = model.settings.outline
                        if outline > 0 {
                            for offset in [CGPoint(x: -outline, y: 0), CGPoint(x: outline, y: 0),
                                           CGPoint(x: 0, y: -outline), CGPoint(x: 0, y: outline)] {
                                context.draw(shadow, at: CGPoint(x: point.x + offset.x, y: point.y + offset.y), anchor: .topLeading)
                            }
                        }
                        context.draw(context.resolve(Text(item.comment.text).font(font).foregroundStyle(color)),
                                     at: point, anchor: .topLeading)
                    }
                }
                .opacity(model.settings.opacity)
            }
            .task(id: LayoutIdentity(revision: model.commentRevision, settings: model.settings,
                                     width: geometry.size.width, height: geometry.size.height)) {
                timeline = DanmakuTimeline(comments: model.visibleComments,
                                           width: geometry.size.width, height: geometry.size.height,
                                           settings: model.settings) { text, size in
                    Double((text as NSString).size(withAttributes: [.font: UIFont.boldSystemFont(ofSize: size)]).width)
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
