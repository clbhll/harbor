import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var scanner: PortScanner

    var body: some View {
        Form {
            Section("Display") {
                Toggle("Hide system processes", isOn: $scanner.hideSystemProcesses)
            }

            Section("About") {
                LabeledContent("App", value: "Harbor")
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                Text("Local servers and ports, quietly in your menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 220)
        .padding()
    }
}
