import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject private var scanner: PortScanner
    @State private var appeared = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            HarborBackground()

            VStack(spacing: 0) {
                header
                searchBar
                content
                footer
            }
        }
        .frame(width: HarborTheme.panelWidth, height: HarborTheme.panelHeight)
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.84).delay(0.05)) {
                appeared = true
            }
            Task { await scanner.refresh() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Harbor")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(Color(red: 0.93, green: 0.95, blue: 0.92))
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 6)

                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.70, green: 0.82, blue: 0.76).opacity(0.85))
                    .opacity(appeared ? 1 : 0)
            }

            Spacer()

            Button {
                Task { await scanner.refresh() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.78, green: 0.90, blue: 0.84))
                    .rotationEffect(.degrees(scanner.isRefreshing ? 360 : 0))
                    .animation(
                        scanner.isRefreshing
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .default,
                        value: scanner.isRefreshing
                    )
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Refresh now")
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var subtitle: String {
        let count = scanner.filteredServers.count
        if count == 0 {
            return "No local servers right now"
        }
        return "\(count) listening \(count == 1 ? "port" : "ports")"
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))

            TextField("Filter by name or port", text: $scanner.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .focused($searchFocused)

            if !scanner.query.isEmpty {
                Button {
                    scanner.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let error = scanner.errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(Color(red: 0.95, green: 0.78, blue: 0.45))
                Text(error)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scanner.filteredServers.isEmpty {
            EmptyStateView(hasQuery: !scanner.query.isEmpty)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(scanner.filteredServers.enumerated()), id: \.element.id) { index, server in
                        ServerRowView(server: server)
                            .padding(.horizontal, 10)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 8)
                            .animation(
                                .spring(response: 0.42, dampingFraction: 0.86)
                                    .delay(0.04 * Double(min(index, 8))),
                                value: appeared
                            )

                        if index < scanner.filteredServers.count - 1 {
                            Rectangle()
                                .fill(.white.opacity(0.06))
                                .frame(height: 1)
                                .padding(.leading, 62)
                                .padding(.trailing, 14)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $scanner.hideSystemProcesses) {
                Text("Hide system")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            Spacer()

            if let updated = scanner.lastUpdated {
                Text("Updated \(updated.relativeShort)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
            .help("Quit Harbor")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.25))
    }
}

private extension Date {
    var relativeShort: String {
        let seconds = Int(-timeIntervalSinceNow)
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}
