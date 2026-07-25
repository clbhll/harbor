import SwiftUI

struct SettingsView: View {
    @Environment(PortScanner.self) private var scanner

    var body: some View {
        @Bindable var scanner = scanner

        Form {
            Section("Display") {
                Toggle("Hide system processes", isOn: $scanner.hideSystemProcesses)
            }

            Section("About") {
                LabeledContent("App", value: "Harbor")
                LabeledContent("Version", value: Self.version)
                Text("Local servers and ports, quietly in your menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 220)
        .padding()
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
