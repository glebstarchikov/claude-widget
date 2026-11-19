import SwiftUI
import AppKit
import ClaudeWidgetCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
            }

            Section("Appearance") {
                HStack(spacing: 10) {
                    ForEach(ThemeID.allCases, id: \.self) { id in swatch(id) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                Toggle("New Year hat", isOn: $model.newYearHat)
                Text("Dec 15 \u{2013} Jan 7")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Notch") {
                Toggle("Open on hover", isOn: $model.hubHoverEnabled)
                Toggle("Show alerts proactively", isOn: $model.notchProactive)
                Toggle("Answer permission prompts", isOn: $model.answerFromNotch)
            }

            Section("Limits") {
                Toggle("Show Claude limits", isOn: $model.limitsEnabled)
            }

            Section("Phone") {
                Toggle("Notify my phone", isOn: $model.pushEnabled)
                if model.pushEnabled {
                    LabeledContent("Topic") {
                        HStack(spacing: 6) {
                            Text(model.pushTopic)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.pushTopic, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .help("Copy topic")
                        }
                    }
                    Button("Send test notification") { model.sendTestPush() }
                    Text("Install the ntfy app, tap +, and paste this topic.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Hooks") {
                LabeledContent("Status") {
                    Text(model.hooksInstalled ? "Installed" : "Not installed")
                        .foregroundStyle(.secondary)
                }
                if model.hooksInstalled {
                    Button("Remove hooks") { model.removeHooks() }
                } else {
                    Button("Install hooks") { model.installHooks() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func color(_ rgb: RGB) -> Color { Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1) }

    /// The custom color as a SwiftUI color; picking one also selects the Custom theme.
    private var customColor: Binding<Color> {
        Binding(
            get: { color(RGB(hex: model.customThemeColor) ?? RGB(r: 0.17, g: 0.7, b: 0.75)) },
            set: { newValue in
                guard let c = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                model.customThemeColor = RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent)).hex
                model.theme = .custom
            }
        )
    }

    @ViewBuilder
    private func swatch(_ id: ThemeID) -> some View {
        let selected = model.theme == id
        Group {
            switch id {
            case .custom:
                ColorPicker("Custom", selection: customColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
            case .system:
                Button { model.theme = id } label: {
                    HStack(spacing: 0) {
                        color(ThemePalette.pair(for: .system, custom: ThemePalette.white).light)
                        color(ThemePalette.pair(for: .system, custom: ThemePalette.white).dark)
                    }
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
                }
                .buttonStyle(.plain)
            default:
                let pair = ThemePalette.pair(for: id, custom: ThemePalette.white)
                Button { model.theme = id } label: {
                    Circle().fill(color(colorScheme == .dark ? pair.dark : pair.light))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(selected ? 1 : 0))
        .help(id.displayName)
        .accessibilityLabel(id.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
