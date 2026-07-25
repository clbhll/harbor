import SwiftUI

enum HarborTheme {
    // MARK: - Palette

    static let brand = Color("HarborBrand")
    static let accent = Color("HarborAccent")
    static let ink = Color("HarborInk")
    static let mist = Color("HarborMist")
    static let glow = Color("HarborGlow")

    // MARK: - Semantic text
    //
    // The panel is locked to dark, so these are tuned against `brandGradient`.
    // Tertiary sits at 0.58 rather than the eyeballed 0.35 it replaced — that
    // lands around 7:1 on the darkest part of the background, where 0.35 was 3.4:1.

    static let textPrimary = mist
    static let textSecondary = Color(red: 0.70, green: 0.82, blue: 0.76)
    static let textTertiary = Color.white.opacity(0.58)
    static let textPlaceholder = Color.white.opacity(0.5)

    /// Non-text decoration only (separators, interpunct). Never put a word in this.
    static let hairline = Color.white.opacity(0.09)
    static let decoration = Color.white.opacity(0.4)

    // MARK: - Semantic accents

    static let port = Color(red: 0.86, green: 0.93, blue: 0.72)
    static let portCopied = Color(red: 0.72, green: 0.92, blue: 0.62)
    static let control = Color(red: 0.78, green: 0.90, blue: 0.84)
    static let warning = Color(red: 0.95, green: 0.78, blue: 0.45)

    // MARK: - Surfaces

    static let surfaceRaised = Color.white.opacity(0.07)
    static let surfaceHover = Color.white.opacity(0.08)
    static let surfaceStroke = Color.white.opacity(0.08)
    static let footerScrim = Color.black.opacity(0.25)

    // MARK: - Metrics

    static let panelWidth: CGFloat = 340
    static let panelHeight: CGFloat = 460
    static let cornerRadius: CGFloat = 12

    // MARK: - Gradients

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.09, green: 0.16, blue: 0.15),
                Color(red: 0.05, green: 0.08, blue: 0.09)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var washGradient: RadialGradient {
        RadialGradient(
            colors: [
                Color(red: 0.22, green: 0.42, blue: 0.36).opacity(0.45),
                Color.clear
            ],
            center: .topTrailing,
            startRadius: 10,
            endRadius: 220
        )
    }
}

struct HarborBackground: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            HarborTheme.brandGradient
            HarborTheme.washGradient
                .scaleEffect(pulse ? 1.08 : 0.92)
                .opacity(pulse ? 0.9 : 0.55)

            Canvas { context, size in
                for x in stride(from: 0, through: size.width, by: 6) {
                    for y in stride(from: 0, through: size.height, by: 6) {
                        let rect = CGRect(x: x, y: y, width: 0.7, height: 0.7)
                        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.035)))
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 4.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
