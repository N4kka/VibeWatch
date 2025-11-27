import SwiftUI

/// A custom toggle with Liquid Glass morphism design
struct LiquidGlassToggle: View {
    @Binding var isOn: Bool
    var onToggle: (() -> Void)? = nil
    
    @State private var isDragging = false
    
    var body: some View {
        ZStack {
            // Background track
            Capsule()
                .fill(isOn ? Color.theme.accentOrange.opacity(0.3) : Color.white.opacity(0.1))
                .frame(width: 51, height: 31)
            
            // Thumb (knob)
            HStack {
                if isOn {
                    Spacer()
                }
                
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        // Inner glow
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.4),
                                        Color.white.opacity(0.1)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        // Border
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.4),
                                        Color.white.opacity(0.2)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
                    .frame(width: 27, height: 27)
                    .scaleEffect(isDragging ? 1.05 : 1.0)
                
                if !isOn {
                    Spacer()
                }
            }
            .frame(width: 51)
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            toggleState()
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    isDragging = true
                }
                .onEnded { _ in
                    isDragging = false
                    toggleState()
                }
        )
    }
    
    private func toggleState() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            isOn.toggle()
        }
        onToggle?()
    }
}

#Preview {
    VStack(spacing: 30) {
        LiquidGlassToggle(isOn: .constant(true))
        LiquidGlassToggle(isOn: .constant(false))
    }
    .padding()
    .background(Color.black)
}
