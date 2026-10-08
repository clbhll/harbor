import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(PortScanner.self) private var scanner
    @State private var appeared = false

    var body: some View {
        ZStack {
            HarborBackground()

            VStack(spacing: 0) {
                header
                SearchField(scanner: scanner)
                if let error = scanner.actionErrorMessage {
                    ErrorBanner(message: error, dismissLabel: "Dismiss action error") {
                        scanner.dismissActionError()
                    }
                }
                if let error = scanner.discoveryErrorMessage {
                    ErrorBanner(
                        message: "Couldn’t refresh ports: \(error)",
                        dismissLabel: "Dismiss discovery error"
                    ) {
                        scanner.dismissDiscoveryError()
                    }
                }
                content
                FooterBar(scanner: scanner)
            }
        }
        .frame(width: HarborTheme.panelWidth, height: HarborTheme.panelHeight)
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.84).delay(0.05)) {
                appeared = true
            }
            scanner.isPanelVisible = true
        }
        .onDisappear {
            scanner.isPanelVisible = false
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Harbor")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(HarborTheme.textPrimary)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 6)

                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(HarborTheme.textSecondary)
                    .opacity(appeared ? 1 : 0)
            }

            Spacer()

            Button {
                Task { await scanner.refresh() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HarborTheme.control)
                    .rotationEffect(.degrees(scanner.isRefreshing ? 360 : 0))
                    .animation(
                        scanner.isRefreshing
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .default,
                        value: scanner.isRefreshing
                    )
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(HarborTheme.surfaceHover))
            }
            .buttonStyle(.plain)
            .disabled(scanner.isRefreshing)
            .accessibilityLabel("Refresh")
            .help(scanner.isRefreshing ? "Refreshing…" : "Refresh now")
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var subtitle: String {
        if !scanner.isDiscoveryTrusted {
            if scanner.lastUpdated != nil { return "Showing last successful scan" }
            return scanner.isRefreshing ? "Checking local ports…" : "Local ports unavailable"
        }
        let count = scanner.filteredServers.count
        if count == 0 {
            return "No local servers right now"
        }
        return "\(count) listening \(count == 1 ? "port" : "ports")"
    }

    @ViewBuilder
    private var content: some View {
        // Read once — this used to be a computed filter the separator check
        // re-ran for every row.
        let servers = scanner.filteredServers

        if servers.isEmpty && !scanner.isDiscoveryTrusted {
            VStack(spacing: 8) {
                if scanner.isRefreshing { ProgressView().controlSize(.small) }
                Text(scanner.isRefreshing ? "Checking local ports…" : "Port information unavailable")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(HarborTheme.textSecondary)
                if !scanner.isRefreshing {
                    Text("Refresh to try again.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(HarborTheme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if servers.isEmpty {
            EmptyStateView(hasQuery: !scanner.query.isEmpty)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                        ServerRowView(server: server)
                            .padding(.horizontal, 10)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 8)
                            .animation(
                                .spring(response: 0.42, dampingFraction: 0.86)
                                    .delay(0.04 * Double(min(index, 8))),
                                value: appeared
                            )

                        if index < servers.count - 1 {
                            Rectangle()
                                .fill(HarborTheme.hairline)
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
}

// MARK: - Search

private struct SearchField: View {
    @Bindable var scanner: PortScanner
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HarborTheme.textTertiary)

            TextField("Filter by name or port", text: $scanner.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(HarborTheme.textPrimary)
                .focused($focused)

            if !scanner.query.isEmpty {
                Button {
                    scanner.query = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(HarborTheme.decoration)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(HarborTheme.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(HarborTheme.surfaceStroke, lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .onAppear { focused = true }
    }
}

// MARK: - Error banner

private struct ErrorBanner: View {
    let message: String
    let dismissLabel: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HarborTheme.warning)

            Text(message)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(HarborTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(HarborTheme.decoration)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dismissLabel)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(HarborTheme.warning.opacity(0.12))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.opacity)
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @Bindable var scanner: PortScanner

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $scanner.hideSystemProcesses) {
                Text("Hide system")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(HarborTheme.textTertiary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            Spacer()

            if let updated = scanner.lastUpdated {
                TimestampLabel(date: updated)
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(HarborTheme.textTertiary)
            .help("Quit Harbor")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(HarborTheme.footerScrim)
    }
}

/// Re-renders itself on a timer so "just now" doesn't go stale while the panel
/// sits open between scans.
private struct TimestampLabel: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: date, by: 5)) { _ in
            Text("Updated \(date.relativeShort)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(HarborTheme.textTertiary)
                .monospacedDigit()
        }
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

