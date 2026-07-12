import SwiftUI
import ClaudeWidgetCore

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SESSIONS")
                .font(Font(Theme.monoFont(11)))
                .kerning(0.8)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            if model.sessions.isEmpty {
                Text("No sessions. The critter sleeps.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                ForEach(Array(model.sessions.enumerated()), id: \.element.sessionId) { index, session in
                    if index > 0 { Divider().padding(.leading, 16) }
                    SessionRow(session: session, dark: colorScheme == .dark)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Toggle("Notch alerts", isOn: $model.notchAlerts)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 13))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            HStack {
                hooksControl
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .onAppear { model.refreshHooksStatus() }
    }

    @ViewBuilder private var hooksControl: some View {
        if model.hooksInstalled {
            HStack(spacing: 6) {
                Text("Hooks installed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Remove") { model.removeHooks() }
                    .font(.system(size: 12))
                    .buttonStyle(.link)
            }
        } else {
            Button("Install hooks") { model.installHooks() }
                .font(.system(size: 13))
        }
    }
}

struct SessionRow: View {
    let session: Session
    let dark: Bool
    @State private var hovering = false

    private var dotColor: Color {
        switch session.state {
        case .working: return Color(nsColor: dark ? Theme.accentDark : Theme.accentLight)
        case .needsYou: return Color(nsColor: Theme.claudeOrange)
        case .waiting: return Color(nsColor: NSColor(hex: dark ? 0x53B483 : 0x1A7A4D))
        case .ready: return Color(nsColor: dark ? Theme.faintDark : Theme.faintLight)
        }
    }

    private var elapsed: String {
        let seconds = max(0, Date().timeIntervalSince1970 - session.updatedAt)
        let minutes = Int(seconds) / 60
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(session.projectName)
                    .font(.system(size: 14))
                Spacer()
                Text(elapsed)
                    .font(Font(Theme.monoFont(12)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
            .onHover { hovering = $0 }
        }
    }
}
