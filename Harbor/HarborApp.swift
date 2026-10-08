import SwiftUI

@main
struct HarborApp: App {
    @State private var scanner = PortScanner()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(scanner)
        } label: {
            MenuBarLabel(count: scanner.filteredServers.count)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(scanner)
        }
    }
}

private struct MenuBarLabel: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "antenna.radiowaves.left.and.right")
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel("Harbor: \(count) local \(count == 1 ? "server" : "servers")")
    }
}
