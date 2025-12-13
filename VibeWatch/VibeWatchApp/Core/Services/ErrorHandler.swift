import Foundation
import SwiftUI
import RevenueCat

/// Centralized error handling service
/// Converts technical errors into a standardized `AppError`
@MainActor
class ErrorHandler: ObservableObject {
    static let shared = ErrorHandler()
    
    @Published var currentError: AppError?
    @Published var showError = false
    
    private init() {}
    
    /// Handle any error and prepare it to be shown to the user.
    func handle(_ error: Error, context: String = "") {
        let appError = convertToAppError(error, context: context)
        
        // Log for debugging
        logError(appError, originalError: error, context: context)
        
        // Show to user
        currentError = appError
        showError = true
    }
    
    /// Handle an error by only logging it, without showing any UI.
    func logOnly(_ error: Error, context: String = "") {
        let appError = convertToAppError(error, context: context)
        logError(appError, originalError: error, context: context)
    }
    
    /// Dismiss the currently shown error.
    func dismiss() {
        showError = false
        currentError = nil
    }
    
    // MARK: - Error Conversion
    
    private func convertToAppError(_ error: Error, context: String) -> AppError {
        // Passthrough if it's already an AppError
        if let appError = error as? AppError {
            return appError
        }
        
        // Check for specific technical error types
        if let authError = error as? AuthError {
            return handleAuthError(authError)
        }
        
        if let listError = error as? ListError {
            return handleListError(listError)
        }
        
        if let rcError = error as? RevenueCat.ErrorCode {
            return handleRevenueCatError(rcError)
        }
        
        if let urlError = error as? URLError {
            return .network(urlError)
        }

        // Check error domain for Supabase/PostgREST
        let nsError = error as NSError
        if nsError.domain.contains("supabase") || nsError.domain.contains("postgrest") {
            return handleSupabaseError(nsError)
        }
        
        // Fallback for any other error
        return .unknown(error)
    }
    
    // MARK: - Specific Error Handlers
    
    private func handleAuthError(_ error: AuthError) -> AppError {
        switch error {
        case .networkError:
            return .network(error)
        default:
            return .unauthorized
        }
    }
    
    private func handleListError(_ error: ListError) -> AppError {
        switch error {
        case .maxListsReached, .maxItemsReached:
            return .quotaExceeded
        case .authenticationRequired:
            return .unauthorized
        default:
            return .database(error)
        }
    }
    
    private func handleRevenueCatError(_ error: RevenueCat.ErrorCode) -> AppError {
        switch error {
        case .networkError, .storeProblemError:
            return .network(error)
        case .receiptAlreadyInUseError, .purchaseInvalidError:
            return .subscriptionExpired
        default:
            return .unknown(error)
        }
    }
    
    private func handleSupabaseError(_ error: NSError) -> AppError {
        if error.code == 401 || error.code == 403 {
            return .unauthorized
        }
        return .database(error)
    }
    
    // MARK: - Logging
    
    private func logError(_ appError: AppError, originalError: Error, context: String) {
        let contextStr = context.isEmpty ? "" : " [\(context)]"
        // Use the localized description from the AppError itself.
        print("❌ [ErrorHandler]\(contextStr) \(appError.localizedDescription)")
        
        // Log to analytics
        AnalyticsService.shared.logEvent("error_handled", parameters: [
            "error_type": String(describing: appError),
            "context": context
        ])
    }
}
