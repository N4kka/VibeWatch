import Foundation
import RevenueCat

/// Central place to interact with RevenueCat SDK.
@MainActor
final class RevenueCatService: ObservableObject {
    static let shared = RevenueCatService()
    
    @Published private(set) var offerings: Offerings?
    @Published private(set) var currentOfferingID: String?
    @Published private(set) var lastRefreshDate: Date?
    
    private init() {}
    
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
            print("❌ [RevenueCat] Failed to fetch offerings: \(error.localizedDescription)")
        }
    }
    
    /// Convenience accessor for a specific offering.
    func offering(with identifier: String) -> Offering? {
        if let current = offerings?.offering(identifier: identifier) {
            return current
        }
        return offerings?.current
    }
    
    /// Prints a human-friendly summary of offerings and packages.
    private func debugPrintOfferings(_ offerings: Offerings) {
        print("\n================ RevenueCat Offerings ================")
        print(offerings)
        print("Current offering: \(offerings.current?.identifier ?? "none")")
        print("Available offerings: \(offerings.all.keys.joined(separator: ", "))")
        
        for (identifier, offering) in offerings.all {
            print("\n🧾 Offering: \(identifier)")
            for package in offering.availablePackages {
                let product = package.storeProduct
                print("  • Package: \(package.identifier)")
                print("    - Product ID: \(product.productIdentifier)")
                print("    - Price: \(product.localizedPriceString)")
                print("    - Subscription period: \(product.subscriptionPeriod?.unit.description ?? "n/a")")
            }
        }
        print("=====================================================\n")
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
