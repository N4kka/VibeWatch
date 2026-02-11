import Foundation
import RevenueCat

/// Central place to interact with RevenueCat SDK.
@MainActor
final class RevenueCatService: ObservableObject {
    static let shared = RevenueCatService()
    
    @Published private(set) var offerings: Offerings?
    @Published private(set) var currentOfferingID: String?
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var debugLoggingEnabled: Bool
    
    private init() {
        #if DEBUG
        self.debugLoggingEnabled = true
        #else
        self.debugLoggingEnabled = false
        #endif
        
        setRevenueCatLogLevel(debugLoggingEnabled)
    }
    
    /// Toggle RevenueCat log level at runtime for QA/debug sessions.
    func setDebugLoggingEnabled(_ enabled: Bool) {
        guard enabled != debugLoggingEnabled else { return }
        debugLoggingEnabled = enabled
        setRevenueCatLogLevel(enabled)
    }
    
    /// Applies the current debug logging preference to RevenueCat.
    func applyCurrentLogLevel() {
        setRevenueCatLogLevel(debugLoggingEnabled)
    }
    
    /// Fetches the latest offerings from RevenueCat and prints useful diagnostics.
    func refreshOfferings(debug: Bool = true) async {
        do {
            let offerings = try await Purchases.shared.offerings()
            self.offerings = offerings
            self.lastRefreshDate = Date()
            self.currentOfferingID = offerings.current?.identifier
            FoundingMemberService.shared.refreshPromoStatus()
            
            if debug {
                debugPrintOfferings(offerings)
            }
        } catch {
            Logger.error("[RevenueCat] Failed to fetch offerings: \(error.localizedDescription)")
        }
    }
    
    /// Convenience accessor for a specific offering.
    func offering(with identifier: String) -> Offering? {
        if let current = offerings?.offering(identifier: identifier) {
            return current
        }
        return offerings?.current
    }
    
    /// Helper to get trial information from a package
    func getTrialInfo(for package: Package) -> TrialInfo? {
        if let discount = package.storeProduct.introductoryDiscount,
           let trial = trialInfo(from: discount) {
            return trial
        }

        // StoreKit 2 products expose subscription options; use reflection so we stay compatible with older SDKs.
        if let options = subscriptionOptionsViaReflection(from: package.storeProduct) {
            for option in options {
                if let intro = introductoryOfferViaReflection(from: option),
                   let trial = trialInfo(from: intro) {
                    return trial
                }
            }
        }

        return nil
    }
    
    /// Format trial duration for display (e.g., "7 days", "1 month")
    private func formatTrialDuration(_ period: SubscriptionPeriod) -> String {
        let value = period.value
        let unitName: String
        
        switch period.unit {
        case .day:
            unitName = value == 1 ? "day" : "days"
        case .week:
            unitName = value == 1 ? "week" : "weeks"
        case .month:
            unitName = value == 1 ? "month" : "months"
        case .year:
            unitName = value == 1 ? "year" : "years"
        @unknown default:
            unitName = "period"
        }
        
        return "\(value) \(unitName)"
    }
    
    /// Prints a human-friendly summary of offerings and packages.
    private func debugPrintOfferings(_ offerings: Offerings) {
        Logger.debug("[RevenueCat] ================ Offerings ================")
        Logger.debug("[RevenueCat] \(offerings)")
        Logger.debug("[RevenueCat] Current offering: \(offerings.current?.identifier ?? "none")")
        Logger.debug("[RevenueCat] Available offerings: \(offerings.all.keys.joined(separator: ", "))")

        for (identifier, offering) in offerings.all {
            Logger.debug("[RevenueCat] Offering: \(identifier)")
            for package in offering.availablePackages {
                let product = package.storeProduct
                Logger.debug("[RevenueCat]   Package: \(package.identifier)")
                Logger.debug("[RevenueCat]     Product ID: \(product.productIdentifier)")
                Logger.debug("[RevenueCat]     Price: \(product.localizedPriceString)")
                Logger.debug("[RevenueCat]     Subscription period: \(product.subscriptionPeriod?.unit.description ?? "n/a")")

                // Show trial info if available
                if let trial = getTrialInfo(for: package) {
                    Logger.debug("[RevenueCat]     FREE TRIAL: \(trial.localizedDuration)")
                }

                // Show intro pricing if available (but not free trial)
                if let discount = product.introductoryDiscount,
                   discount.paymentMode != .freeTrial {
                    Logger.debug("[RevenueCat]     INTRO PRICE: \(discount.price) for \(formatTrialDuration(discount.subscriptionPeriod))")
                }
            }
        }
        Logger.debug("[RevenueCat] =====================================================")
    }
}

/// Information about a free trial offer
struct TrialInfo {
    let duration: Int
    let unit: SubscriptionPeriod.Unit
    let localizedDuration: String // e.g., "7 days", "1 month"
}

private extension RevenueCatService {
    func trialInfo(from discount: StoreProductDiscount) -> TrialInfo? {
        guard discount.paymentMode == .freeTrial else { return nil }
        let period = discount.subscriptionPeriod
        return TrialInfo(
            duration: period.value,
            unit: period.unit,
            localizedDuration: formatTrialDuration(period)
        )
    }
    
    func setRevenueCatLogLevel(_ debug: Bool) {
        Purchases.logLevel = debug ? .debug : .info
        Logger.debug("[RevenueCat] Log level set to \(debug ? "debug" : "info")")
    }

    /// Reflection helpers keep compatibility with RevenueCat builds that don't expose StoreKit 2 subscriptionOptions in the public API.
    func subscriptionOptionsViaReflection(from product: StoreProduct) -> [Any]? {
        Mirror(reflecting: product).descendant("subscriptionOptions") as? [Any]
    }

    func introductoryOfferViaReflection(from option: Any) -> StoreProductDiscount? {
        Mirror(reflecting: option).descendant("introductoryOffer") as? StoreProductDiscount
    }
}


private extension SubscriptionPeriod.Unit {
    var description: String {
        switch self {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        @unknown default: return "unknown"
        }
    }
}
