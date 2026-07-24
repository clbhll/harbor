import SwiftUI

enum HarborTheme {
    static let brand = Color("HarborBrand")
    static let accent = Color("HarborAccent")
    static let ink = Color("HarborInk")
    static let mist = Color("HarborMist")
    static let glow = Color("HarborGlow")

    static let panelWidth: CGFloat = 340
    static let panelHeight: CGFloat = 460

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
