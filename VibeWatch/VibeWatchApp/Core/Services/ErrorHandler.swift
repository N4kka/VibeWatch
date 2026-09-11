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
        if let authError = error as? AppAuthError {
            return handleAuthError(authError)
        }
        
        if let listError = error as? ListError {
            return handleListError(listError)
        }

        if let supabaseError = error as? SupabaseError {
            return handleSupabaseServiceError(supabaseError)
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
    
    private func handleAuthError(_ error: AppAuthError) -> AppError {
        switch error {
        case .networkError:
            return .network(error)
        case .custom(_):
            // Map custom auth errors to unknown with message, or a specific type if available
            // For now, let's treat it as a database or unknown error but preserve description
            // Actually, ErrorHandler converts TO AppError. 
            // AppError probably has .unknown(Error) or similar.
            // Let's check AppError definition. Assuming .unknown takes Error.
            // If message is string, we might need a custom error type.
            // Let's just return .unknown with a custom NSError?
            // Or better, let's map .custom to .unknown for now as AppError might not have .custom
            return .unknown(error)
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
    
    /// `SupabaseError` è un enum Swift, non un `NSError` con dominio "supabase": senza questo
    /// ramo cadeva in `.unknown`, e una sessione da rifare compariva come "An unexpected error
    /// occurred" — la diagnosi peggiore possibile, perché non dice l'unica cosa che l'utente
    /// può fare.
    private func handleSupabaseServiceError(_ error: SupabaseError) -> AppError {
        switch error {
        case .notAuthenticated, .sessionExpired, .authenticationFailed:
            return .unauthorized
        case .networkError:
            return .network(error)
        case .httpError(let statusCode, _) where statusCode == 401 || statusCode == 403:
            return .unauthorized
        case .notConfigured, .httpError, .unexpectedResponse:
            return .database(error)
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
        Logger.error("[ErrorHandler]\(contextStr) \(appError.localizedDescription)")

        // A handled error becomes a $exception in PostHog error tracking (grouped by type, with
        // stack context) — replaces the old flat `error_handled` event.
        CrashReportingService.record(originalError, context: context.isEmpty ? String(describing: appError) : context)

        // An error makes the session worth watching: start recording from here.
        AnalyticsService.shared.replay.trigger(.errorHandled)
    }
}
