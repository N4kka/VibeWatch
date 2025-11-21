import SwiftUI

struct LiquidGlassView: View {
    var cornerRadius: CGFloat = 0
    var opacity: Double = 1.0
    
    var body: some View {
        ZStack {
            // Base frosted glass effect
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.ultraThinMaterial)
                .opacity(opacity)
            
            // Subtle gradient overlay for depth
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.15),
                            Color.white.opacity(0.05),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            // Border highlight
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.3),
                            Color.white.opacity(0.1),
                            Color.white.opacity(0.2)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }
}

struct LiquidGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 0
    var opacity: Double = 1.0
    
    func body(content: Content) -> some View {
        content
            .background {
                LiquidGlassView(cornerRadius: cornerRadius, opacity: opacity)
            }
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 0, opacity: Double = 1.0) -> some View {
        modifier(LiquidGlassModifier(cornerRadius: cornerRadius, opacity: opacity))
    }
}

#Preview {
    LiquidGlassView()
}
