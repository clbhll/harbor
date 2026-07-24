import SwiftUI
import AppKit

struct ServerRowView: View {
    let server: ListeningServer
    @State private var isHovering = false
    @State private var copiedFlash = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: server.appIcon(size: 36))
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .shadow(color: .black.opacity(isHovering ? 0.35 : 0.15), radius: isHovering ? 6 : 2, y: 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(server.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.94, green: 0.96, blue: 0.93))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(server.addressLabel)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.62, green: 0.76, blue: 0.70))
                    Text("·")
                        .foregroundStyle(.white.opacity(0.25))
                    Text("pid \(server.pid)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }

            Spacer(minLength: 8)

            Text("\(server.port)")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(
                    copiedFlash
                        ? Color(red: 0.72, green: 0.92, blue: 0.62)
                        : Color(red: 0.86, green: 0.93, blue: 0.72)
                )
                .scaleEffect(isHovering ? 1.04 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isHovering)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(isHovering ? 0.08 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            Button("Terminate Process", role: .destructive) {
                PortActions.terminate(server)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(server.displayName), port \(server.port)")
        .accessibilityHint("Open localhost in browser. Right-click for more actions.")
        .help("Click to open · Right-click for actions")
    }

    private func flashCopied() {
        withAnimation(.easeOut(duration: 0.15)) {
            copiedFlash = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeOut(duration: 0.25)) {
                copiedFlash = false
            }
        }
    }
}
