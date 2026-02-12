import SwiftUI

struct CheckEmailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appState: AppState
    
    let email: String
    var onVerified: () -> Void
    var onResend: () -> Void
    var onChangeEmail: () -> Void
    
    @State private var isChecking = false
    
    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()
            
            VStack(spacing: 32) {
                Spacer()
                
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.theme.accentOrange.opacity(0.1))
                        .frame(width: 120, height: 120)
                    
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(Color.theme.accentOrange)
                }
                
                // Text
                VStack(spacing: 16) {
                    Text("auth.checkEmailTitle".localized)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                        .multilineTextAlignment(.center)
                    
                    Text("auth.checkEmailMessage".localized)
                        .font(.system(size: 16))
                        .foregroundColor(.theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .lineSpacing(4)
                    
                    Text(email)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                }
                
                Spacer()
                
                // Actions
                VStack(spacing: 16) {
                    Button(action: openMailApp) {
                        Text("auth.openMailApp".localized)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Color.theme.accentOrange)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    
                    Button(action: {
                        Task {
                            isChecking = true
                            await authService.checkAuthState()
                            if authService.isAuthenticated {
                                onVerified()
                            } else {
                                // Maybe show a toast "Still waiting for verification..."
                                AppState.shared.toastMessage = "auth.verificationPending".localized
                                AppState.shared.showErrorToast = true
                            }
                            isChecking = false
                        }
                    }) {
                        HStack {
                            if isChecking {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text("auth.iHaveVerified".localized)
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(.theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    
                    HStack {
                        Button("auth.resendEmail".localized) {
                            onResend()
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.theme.accentOrange)
                        
                        Text("•")
                            .foregroundColor(.theme.textSecondary)
                        
                        Button("auth.changeEmail".localized) {
                            onChangeEmail()
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.theme.textSecondary)
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task {
                await authService.checkAuthState()
                if authService.isAuthenticated {
                    onVerified()
                }
            }
        }
    }
    
    private func openMailApp() {
        let schemes = [
            "googlegmail://", // Gmail
            "ms-outlook://",  // Outlook
            "readdle-spark://", // Spark
            "ymail://",       // Yahoo
            "message://"      // Apple Mail
        ]
        
        for scheme in schemes {
            if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }
        
        // Fallback
        if let url = URL(string: "mailto:") {
            UIApplication.shared.open(url)
        }
    }
}
