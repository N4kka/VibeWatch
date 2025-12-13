import SwiftUI

/// A view that displays a standardized, user-friendly alert for a given `AppError`.
struct ErrorAlert: View {
    let error: AppError
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void
    
    init(
        error: AppError,
        onRetry: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.error = error
        self.onRetry = onRetry
        // The onUpgrade parameter is removed as it's not supported by the new AppError model directly.
        self.onDismiss = onDismiss
    }
    
    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
            
            // Alert card
            VStack(spacing: 0) {
                // Generic Icon
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.orange)
                    .padding(.top, 32)
                    .padding(.bottom, 16)
                
                // Title from error description
                Text(error.localizedDescription)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                
                // Message from recovery suggestion
                if let recovery = error.recoverySuggestion {
                    Text(recovery)
                        .font(.system(size: 16))
                        .foregroundColor(.theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                // Actions
                HStack(spacing: 0) {
                    // Dismiss button (always present)
                    Button(action: onDismiss) {
                        Text("common.dismiss".localized)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.theme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    
                    // Retry button (conditionally present)
                    if let onRetry = onRetry {
                        Divider().background(Color.white.opacity(0.1))
                        Button(action: {
                            onDismiss()
                            onRetry()
                        }) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("common.retry".localized)
                            }
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.theme.accentOrange)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                        }
                    }
                }
            }
            .frame(width: 320)
            .background(Color.theme.backgroundDark)
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.3), radius: 20)
        }
        .transition(.scale.combined(with: .opacity))
        .zIndex(999)
    }
}

// MARK: - View Modifier

struct ErrorHandling: ViewModifier {
    @StateObject private var errorHandler = ErrorHandler.shared
    let onRetry: (() -> Void)?
    
    // onUpgrade is removed from here as well.
    func body(content: Content) -> some View {
        ZStack {
            content
            
            if errorHandler.showError, let error = errorHandler.currentError {
                ErrorAlert(
                    error: error,
                    onRetry: onRetry,
                    onDismiss: {
                        withAnimation {
                            errorHandler.dismiss()
                        }
                    }
                )
            }
        }
    }
}

extension View {
    /// Add automatic error handling to any view.
    /// - Parameter onRetry: An optional closure to be executed when the user taps the 'Retry' button.
    func withErrorHandling(
        onRetry: (() -> Void)? = nil
    ) -> some View {
        modifier(ErrorHandling(onRetry: onRetry))
    }
}

#Preview {
    ZStack {
        Color.theme.background.ignoresSafeArea()
        
        ErrorAlert(
            error: .network(URLError(.notConnectedToInternet)),
            onRetry: {},
            onDismiss: {}
        )
    }
}
