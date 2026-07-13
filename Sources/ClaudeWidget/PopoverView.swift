import SwiftUI
import AppKit
import ClaudeWidgetCore

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.sessions.isEmpty ? "SESSIONS" : "SESSIONS · \(model.sessions.count)")
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
                    if index > 0 { Divider() }
                    SessionRow(session: session, dark: colorScheme == .dark)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Toggle("Notch peek", isOn: $model.notchAlerts)
                if model.notchAlerts {
                    Toggle("Show proactively", isOn: $model.notchProactive)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
                Toggle("Notify my phone", isOn: $model.pushEnabled)
                if model.pushEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(model.pushTopic)
                                .font(Font(Theme.monoFont(11)))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.pushTopic, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .help("Copy topic")
                            Spacer()
                            Button("Send test") { model.sendTestPush() }
                                .font(.system(size: 11))
                        }
                        Text("Install the ntfy app → tap +, paste this topic")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 20)
                }
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
        .frame(width: 320)
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

    private var accent: Color { Color(nsColor: dark ? Theme.accentDark : Theme.accentLight) }

    private var dotColor: Color {
        switch session.state {
        case .working: return accent
        case .needsYou: return Color(nsColor: Theme.claudeOrange)
        case .waiting: return Color(nsColor: NSColor(hex: dark ? 0x53B483 : 0x1A7A4D))
        case .ready: return Color(nsColor: dark ? Theme.faintDark : Theme.faintLight)
        }
    }

    private var statusWord: String {
        switch session.state {
        case .working: return "working"
        case .needsYou: return "needs you"
        case .waiting: return "waiting for you"
        case .ready: return "ready"
        }
    }

    private var detail: String {
        if session.state == .needsYou, let m = session.message { return "needs you · \(m)" }
        if let tool = session.tool { return "\(statusWord) · \(tool)" }
        return statusWord
    }

    private var detailColor: Color {
        session.state == .needsYou ? Color(nsColor: Theme.claudeOrange) : .secondary
    }

    private func elapsed(_ now: Double) -> String {
        let minutes = Int(max(0, now - session.updatedAt)) / 60
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func formatTokens(_ n: Int) -> String {
        n >= 1000 ? "\((n + 500) / 1000)k" : "\(n)"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                    Text(session.projectName).font(.system(size: 14))
                    if let model = session.model {
                        Text(model)
                            .font(Font(Theme.monoFont(10)))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(accent.opacity(0.4), lineWidth: 0.5))
                    }
                    if let ctx = session.contextTokens {
                        Text("\(Self.formatTokens(ctx)) ctx")
                            .font(Font(Theme.monoFont(10)))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(elapsed(context.date.timeIntervalSince1970))
                        .font(Font(Theme.monoFont(12)))
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(Font(Theme.monoFont(11)))
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
                    .padding(.leading, 15)

                ForEach(session.subagents, id: \.agentId) { sub in
                    HStack(spacing: 6) {
                        Text("└").font(.system(size: 11)).foregroundStyle(.tertiary)
                        Circle().fill(accent).frame(width: 5, height: 5)
                        Text(sub.agentType).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.8))
                        if let tool = sub.tool {
                            Text("· \(tool)").font(Font(Theme.monoFont(11))).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.leading, 15)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
            .contentShape(Rectangle())
            .onTapGesture {
                if let bid = session.ownerBundleId { activateOwnerApp(bid) }
            }
            .onHover { hovering = $0 }
            .help(session.ownerBundleId != nil ? "Jump to the app running this session" : "")
        }
    }
}

/// Bring the app that launched a session (its owner) to the front.
@MainActor
func activateOwnerApp(_ bundleId: String) {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
        app.activate()
    } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
