import SwiftUI
import ClaudeWidgetCore

/// The hub's Limits module: one ring per usage window in feed order, the
/// soonest reset, and a gear to Settings. Failures stay inside the module as
/// secondary text, over the last numbers if there are any (spec §7).
struct LimitsModule: View {
    let state: LimitsState
    let fromCache: Bool
    let saveFailed: Bool
    let openSettings: () -> Void

    /// Live, cached, or the last numbers before a failure.
    private var usage: ProviderUsage? {
        switch state {
        case .ok(let usage): return usage
        case .expired(let last), .unavailable(let last): return last
        case .off, .loading: return nil
        }
    }

    private var failed: Bool {
        switch state {
        case .expired, .unavailable: return true
        case .off, .loading, .ok: return false
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 14) {
                if let usage {
                    HStack(spacing: 12) {
                        ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                            UsageRing(window: window)
                        }
                    }
                    .opacity(failed ? 0.5 : 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(usage?.provider ?? "Claude")
                            .font(.system(size: 13, weight: .semibold))
                        if let reset = resetText(now: context.date) {
                            Text("· \(reset)")
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(notes(now: context.date), id: \.self) { note in
                        Text(note)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, SessionRow.horizontalPadding)
            .frame(height: HubLayout.limitsHeight)
        }
    }

    /// "<window> resets in …" for the window that resets soonest.
    private func resetText(now: Date) -> String? {
        let upcoming = (usage?.windows ?? []).compactMap { window -> (label: String, at: Date)? in
            guard let at = window.resetsAt, at > now else { return nil }
            return (window.label, at)
        }
        guard let soonest = upcoming.min(by: { $0.at < $1.at }) else { return nil }
        return "\(soonest.label) resets in \(ResetFormat.resetsIn(soonest.at, now: now))"
    }

    /// The state's copy, how old the numbers are when they aren't live, and the
    /// unsaved-sign-in warning.
    private func notes(now: Date) -> [String] {
        var status: [String] = []
        switch state {
        case .loading: status.append("Checking limits…")
        case .expired: status.append("Sign-in expired · run /login in terminal Claude")
        case .unavailable: status.append("Limits unavailable")
        case .off, .ok: break
        }
        if let usage, failed || fromCache { status.append(Self.age(of: usage.fetchedAt, now: now)) }
        var notes = status.isEmpty ? [] : [status.joined(separator: " · ")]
        if saveFailed { notes.append("Couldn't save the renewed sign-in") }
        return notes
    }

    private static func age(of date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "updated just now" }
        if minutes < 60 { return "updated \(minutes)m ago" }
        if minutes < 1440 { return "updated \(minutes / 60)h ago" }
        return "updated \(minutes / 1440)d ago"
    }
}

/// One usage window: a ring filled to its percent (indigo, system red from 90 %),
/// the percent inside, the window's label under it. The active limit's label is emphasized.
private struct UsageRing: View {
    static let diameter: CGFloat = 36
    static let lineWidth: CGFloat = 4

    let window: UsageWindow
    @Environment(\.colorScheme) private var colorScheme

    private var percent: Int { Int(window.percent.rounded()) }

    private var color: Color {
        if window.percent >= 90 { return .red }
        return Color(nsColor: colorScheme == .dark ? Theme.accentDark : Theme.accentLight)
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: Self.lineWidth)
                Circle()
                    .trim(from: 0, to: min(max(window.percent / 100, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(percent)%")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(width: Self.diameter, height: Self.diameter)
            Text(window.label)
                .font(.system(size: 10, weight: window.isActive ? .semibold : .regular))
                .foregroundStyle(window.isActive ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label), \(percent) percent")
    }
}
