import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
            }

            Section("Notch") {
                Toggle("Open on hover", isOn: $model.hubHoverEnabled)
                Toggle("Show alerts proactively", isOn: $model.notchProactive)
                Toggle("Answer permission prompts", isOn: $model.answerFromNotch)
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
        .onAppear { model.refreshHooksStatus() }
    }
}
