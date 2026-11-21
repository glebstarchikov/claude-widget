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
                Button(action: openApp) {
                    HStack(spacing: 12) {
                        artworkView
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title)
                                .font(.system(size: 13, weight: .semibold))
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
                }
                .buttonStyle(.borderless)
                .help("Open \(track.appName ?? "the player")")
                Spacer(minLength: 8)
                HStack(spacing: 14) {
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
            Image(systemName: symbol).font(.system(size: 14))
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}
