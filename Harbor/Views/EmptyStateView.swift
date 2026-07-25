import SwiftUI

struct EmptyStateView: View {
    let hasQuery: Bool
    @State private var bob = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.25, green: 0.45, blue: 0.38).opacity(0.35))
                    .frame(width: 64, height: 64)
                    .scaleEffect(bob ? 1.08 : 0.94)

                Image(systemName: hasQuery ? "line.3.horizontal.decrease.circle" : "water.waves")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(HarborTheme.control)
                    .offset(y: bob ? -2 : 2)
            }

            VStack(spacing: 6) {
                Text(hasQuery ? "Nothing matches" : "Quiet harbor")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(HarborTheme.textPrimary)

                Text(hasQuery
                     ? "Try another name or port."
                     : "Start a local server and it will appear here.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(HarborTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
        }
        .accessibilityElement(children: .combine)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                bob = true
            }
        }
    }
}
