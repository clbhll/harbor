import AppKit
import SwiftUI

struct ServerRowView: View {
    let server: ListeningServer

    @Environment(PortScanner.self) private var scanner
    @State private var isHovering = false
    @State private var copiedFlash = false
    @State private var confirmingTerminate = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIconCache.icon(forExecutableAt: server.executablePath, size: 32))
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .shadow(color: .black.opacity(isHovering ? 0.35 : 0.15), radius: isHovering ? 6 : 2, y: 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(server.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(HarborTheme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(server.addressLabel)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(HarborTheme.textSecondary)
                    Text("·")
                        .foregroundStyle(HarborTheme.decoration)
                    Text("pid \(server.pid)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(HarborTheme.textTertiary)
                }
            }

            Spacer(minLength: 8)

            Text("\(server.port)")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(copiedFlash ? HarborTheme.portCopied : HarborTheme.port)
                .scaleEffect(isHovering ? 1.04 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isHovering)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: HarborTheme.cornerRadius, style: .continuous)
                .fill(isHovering ? HarborTheme.surfaceHover : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: HarborTheme.cornerRadius, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            PortActions.openInBrowser(server)
        }
        .contextMenu {
            Button("Open in Browser") {
                PortActions.openInBrowser(server)
            }
            Button("Copy URL") {
                PortActions.copyURL(server)
                flashCopied()
            }
            Button("Copy Port") {
                PortActions.copyPort(server)
                flashCopied()
            }
            Divider()
            if server.executablePath != nil {
                Button("Reveal Executable") {
                    PortActions.revealInFinder(server)
                }
            }
            Divider()
            Button("Terminate Process…", role: .destructive) {
                confirmingTerminate = true
            }
        }
        .confirmationDialog(
            "Terminate \(server.displayName)?",
            isPresented: $confirmingTerminate,
            titleVisibility: .visible
        ) {
            Button("Terminate", role: .destructive) { terminate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sends SIGTERM to pid \(server.pid), which is listening on port \(server.port). Unsaved work in that process may be lost.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(server.displayName), port \(server.port)")
        .accessibilityHint("Open localhost in browser. Right-click for more actions.")
        .help("Click to open · Right-click for actions")
    }

    private func terminate() {
        guard PortActions.terminate(server) else {
            scanner.report(PortActions.terminationFailureMessage(for: server))
            return
        }
        // Signal delivery is async — give the process a beat to go down before
        // rescanning, so the row actually disappears.
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            await scanner.refresh()
        }
    }

    private func flashCopied() {
        Task {
            withAnimation(.easeOut(duration: 0.15)) { copiedFlash = true }
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeOut(duration: 0.25)) { copiedFlash = false }
        }
    }
}
