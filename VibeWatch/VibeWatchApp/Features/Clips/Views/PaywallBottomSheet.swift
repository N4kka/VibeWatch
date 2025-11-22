import SwiftUI

struct PaywallBottomSheet: View {
    @StateObject private var quotaManager = DailyQuotaManager.shared
    @Environment(\.dismiss) private var dismiss
    @Binding var isPresented: Bool
    
    @State private var currentTime = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            // Blurred background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .blur(radius: 20)
            
            VStack(spacing: 0) {
                Spacer()
                
                // Bottom sheet content
                VStack(spacing: 24) {
                    // Drag indicator
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.4))
                        .frame(width: 40, height: 5)
                        .padding(.top, 12)
                    
                    // Header with emoji
                    VStack(spacing: 12) {
                        Text("🎬")
                            .font(.system(size: 60))
                        
                        Text("You've watched your 15 free clips today")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        Text("Unlock unlimited clips to keep discovering amazing content")
                            .font(.system(size: 16))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    
                    // Feature list
                    VStack(alignment: .leading, spacing: 16) {
                        FeatureRow(icon: "infinity", text: "Unlimited clips every day")
                        FeatureRow(icon: "sparkles", text: "AI-powered personalization")
                        FeatureRow(icon: "bolt.fill", text: "Ad-free experience")
                        FeatureRow(icon: "wand.and.stars", text: "Early access to new features")
                    }
                    .padding(.horizontal, 24)
                    
                    // Upgrade button
                    Button {
                        handleUpgrade()
                    } label: {
                        HStack(spacing: 8) {
                            Text("Upgrade to Pro")
                                .font(.system(size: 18, weight: .bold))
                            
                            Text("€9.99/month")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            LinearGradient(
                                colors: [Color.orange, Color.orange.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(16)
                        .shadow(color: Color.orange.opacity(0.3), radius: 10, x: 0, y: 5)
                    }
                    .padding(.horizontal, 24)
                    
                    // Secondary action - Come back tomorrow
                    VStack(spacing: 8) {
                        Button {
                            dismiss()
                        } label: {
                            HStack(spacing: 6) {
                                Text("Come back tomorrow")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.gray)
                                
                                Image(systemName: "arrow.forward")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.gray)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.gray.opacity(0.15))
                            .cornerRadius(14)
                        }
                        
                        // Countdown timer
                        HStack(spacing: 4) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.gray.opacity(0.7))
                            
                            Text("Resets in \(quotaManager.timeUntilResetFormatted())")
                                .font(.system(size: 13))
                                .foregroundColor(.gray.opacity(0.7))
                        }
                        .onReceive(timer) { _ in
                            currentTime = Date()
                        }
                    }
                    .padding(.horizontal, 24)
                    
                    // Sign in reminder for anonymous users
                    if SupabaseService.shared.currentUser == nil {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.blue.opacity(0.8))
                            
                            Text("Sign in to unlock 15 new clips tomorrow")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.blue.opacity(0.8))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(12)
                        .padding(.horizontal, 24)
                    }
                    
                    // Terms
                    Text("Subscription auto-renews. Cancel anytime.")
                        .font(.system(size: 11))
                        .foregroundColor(.gray.opacity(0.6))
                        .padding(.top, 4)
                        .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(UIColor.systemBackground))
                        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: -10)
                )
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isPresented)
    }
    
    // MARK: - Actions
    
    private func handleUpgrade() {
        // TODO: Integrate with RevenueCat for actual payment
        print("💳 [Paywall] Upgrade button tapped - RevenueCat integration needed")
        
        // For now, just simulate Pro upgrade for testing
        #if DEBUG
        quotaManager.upgradeToPro()
        dismiss()
        #endif
        
        // In production, this will trigger:
        // 1. RevenueCat purchase flow
        // 2. Receipt validation
        // 3. Update user to Pro status
        // 4. Dismiss sheet
    }
}

// MARK: - Supporting Views

struct FeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.orange)
                .frame(width: 24)
            
            Text(text)
                .font(.system(size: 15))
                .foregroundColor(.white)
            
            Spacer()
        }
    }
}

// MARK: - Preview

#Preview {
    PaywallBottomSheet(isPresented: .constant(true))
        .preferredColorScheme(.dark)
}
