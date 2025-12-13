import Foundation

enum AppError: LocalizedError, Identifiable {
    case network(Error)
    case database(Error)
    case unauthorized
    case quotaExceeded
    case subscriptionExpired
    case noContentAvailable
    case unknown(Error? = nil)
    
    public var id: String {
        self.localizedDescription
    }
    
    var errorDescription: String? {
        switch self {
        case .network: return "Network connection failed"
        case .database(let error):
            return (error as? LocalizedError)?.errorDescription ?? "Failed to load data"
        case .unauthorized: return "Please sign in to continue"
        case .quotaExceeded: return "You've reached your daily limit"
        case .subscriptionExpired: return "Your Pro subscription has expired"
        case .noContentAvailable: return "No Clips Available"
        case .unknown: return "An unexpected error occurred"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .network: return "Please check your internet connection and try again."
        case .unauthorized: return "You can sign in or create an account from the profile tab."
        case .quotaExceeded: return "Upgrade to Pro for unlimited access."
        case .subscriptionExpired: return "Please renew your subscription to continue using Pro features."
        case .noContentAvailable: return "We couldn't find any clips for you right now. Please try again later."
        default: return "Please try again later."
        }
    }
}
