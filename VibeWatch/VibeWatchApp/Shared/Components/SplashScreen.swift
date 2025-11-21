import SwiftUI

struct SplashScreen: View {
    @State private var scale: CGFloat = 0.7
    @State private var opacity: Double = 0
    
    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()
            
            VStack(spacing: 24) {
                // Logo
                Image("app_logo")
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.theme.accentOrange, .theme.accentOrange.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .scaleEffect(scale)
                    .opacity(opacity)
                
                // App Name
                Text("VibeWatch")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .opacity(opacity)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.6)) {
                scale = 1.0
                opacity = 1.0
            }
        }
    }
}

#Preview {
    SplashScreen()
}
