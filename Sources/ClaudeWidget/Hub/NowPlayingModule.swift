import SwiftUI
import ClaudeWidgetCore

/// The hub's music card: artwork, title, "Artist · App", a thin progress bar,
/// and back / play-pause / next. The progress ticks once a second; the card
/// lives in the expanded hub, so that only runs while the hub is open.
struct NowPlayingModule: View {
    static let artworkSize: CGFloat = 44

    let track: NowPlaying
    let artwork: NSImage?
    let command: (NowPlayingCommand) -> Void
    let openApp: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 12) {
                // A tap gesture, not a Button: the hub panel is never key, and a Button's
                // label dims in a non-key window (AgentsModule's rows do the same).
                HStack(spacing: 12) {
                    artworkView
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(track.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let progress = track.progress(at: context.date) {
                            progressBar(min(max(progress, 0), 1))
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: openApp)
                .help("Open \(track.appName ?? "the player")")
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "Open app", openApp)
                Spacer(minLength: 8)
                // 3 pt between 28 pt targets keeps the symbols 31 pt apart, as at 14 pt spacing.
                HStack(spacing: 3) {
                    control("backward.fill", label: "Previous") { command(.previous) }
                    control(track.isPlaying ? "pause.fill" : "play.fill",
                            label: track.isPlaying ? "Pause" : "Play") { command(.togglePlayPause) }
                    control("forward.fill", label: "Next") { command(.next) }
                }
            }
            .padding(.horizontal, SessionRow.horizontalPadding)
            .frame(height: HubLayout.nowPlayingHeight)
        }
    }

    @ViewBuilder private var artworkView: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            if let artwork {
                Image(nsImage: artwork).resizable().scaledToFill()
            } else {
                ZStack {
                    shape.fill(.quaternary)
                    Image(systemName: "music.note").font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: Self.artworkSize, height: Self.artworkSize)
        .clipShape(shape)
    }

    private func progressBar(_ fraction: Double) -> some View {
        Capsule().fill(.quaternary)
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(Color(nsColor: Theme.accent(dark: colorScheme == .dark)))
                        .frame(width: proxy.size.width * fraction)
                }
            }
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())   // the whole 28 pt square takes the click
        }
        .buttonStyle(AsIsButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Draws the label as-is. `.borderless` dims its label in a window that isn't key,
/// and the hub panel never is; a press still dims a little.
private struct AsIsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
