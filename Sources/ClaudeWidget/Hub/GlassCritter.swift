import SwiftUI
import AppKit
import ClaudeWidgetCore

/// The critter for hub surfaces, animated to mirror the menu bar critter for
/// the same state: walks while working, pulses when Claude needs you, blinks
/// when ready/waiting, sleeps when there's nothing. Colors come from the same
/// `Theme.critterColor` the status item uses, following the glass's light/dark.
struct GlassCritter: View {
    let state: AggregateState
    var size: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let (color, opacity) = Theme.critterColor(state: state, darkAppearance: colorScheme == .dark)
        Group {
            if reduceMotion {
                image(state == .asleep ? .asleep : .idle, color, opacity)
            } else {
                switch state {
                case .working:
                    TimelineView(.periodic(from: .now, by: WidgetConstants.walkFrameDuration)) { context in
                        let step = Int(context.date.timeIntervalSinceReferenceDate / WidgetConstants.walkFrameDuration)
                        image(step.isMultiple(of: 2) ? .walkA : .walkB, color, opacity)
                    }
                case .needsYou:
                    PulseCritter(color: color, opacity: opacity, size: size)
                case .ready, .waiting:
                    BlinkCritter(color: color, opacity: opacity, size: size)
                case .asleep:
                    image(.asleep, color, opacity)
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func image(_ pose: CritterPose, _ color: NSColor, _ opacity: CGFloat) -> Image {
        Image(nsImage: CritterRenderer.image(pose: pose, color: color, opacity: opacity, pointSize: size))
    }
}

extension SessionState {
    /// The critter state for a single session.
    var critterState: AggregateState {
        switch self {
        case .ready: return .ready
        case .working: return .working
        case .needsYou: return .needsYou
        case .waiting: return .waiting
        }
    }
}

/// Idle critter with the menu bar's opacity pulse, for needs-you.
private struct PulseCritter: View {
    let color: NSColor
    let opacity: CGFloat
    let size: CGFloat
    @State private var dim = false

    var body: some View {
        Image(nsImage: CritterRenderer.image(pose: .idle, color: color, opacity: opacity, pointSize: size))
            .opacity(dim ? 0.55 : 1.0)
            .animation(.easeInOut(duration: WidgetConstants.pulsePeriod / 2).repeatForever(autoreverses: true),
                       value: dim)
            .onAppear { dim = true }
    }
}

/// Idle critter with the menu bar's occasional blink, for ready/waiting.
/// Mirrors StatusItemController.scheduleBlink: eyes shut ~0.12s every 4–7s.
private struct BlinkCritter: View {
    let color: NSColor
    let opacity: CGFloat
    let size: CGFloat
    @State private var pose: CritterPose = .idle

    var body: some View {
        Image(nsImage: CritterRenderer.image(pose: pose, color: color, opacity: opacity, pointSize: size))
            .task {
                while !Task.isCancelled {
                    let gap = Double.random(in: WidgetConstants.blinkIntervalRange)
                    try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
                    pose = .blink
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    pose = .idle
                }
            }
    }
}
