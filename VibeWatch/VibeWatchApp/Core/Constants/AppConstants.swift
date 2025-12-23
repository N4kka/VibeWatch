import Foundation
import CoreGraphics

enum AppConstants {
    enum Clips {
        static let freeUserDailyLimit = 25
        static let maxClipDurationSeconds = 180
        static let paginationThreshold = 5
        static let batchLoadCount = 20
    }
    
    enum Cache {
        static let imageMemoryMB = 50
        static let imageDiskMB = 200
        static let clipsPreloadCount = 5
    }
    
    enum UI {
        static let minimumLoadingDuration: TimeInterval = 2.0
        static let defaultAnimationDuration: TimeInterval = 0.3
    }
    
    enum AI {
        /// Daily request allowance by tier
        static let proDailyRequestLimit = 20
        static let freeDailyRequestLimit = 5
    }
    
    enum Debug {
        /// Set to true while developing to force Pro mode (skips entitlement check)
        static let forceProUser = false
    }
    
    /// RevenueCat subscription and entitlement identifiers
    enum RevenueCat {
        /// The entitlement identifier for Pro features
        /// This must match the entitlement configured in RevenueCat dashboard
        static let proEntitlementID = "StartingVibe Pro"
        
        /// Offering identifiers
        enum Offerings {
            static let foundingMember = "founding_member"
            static let standard = "default"
        }
        
        /// Product identifiers (if you need to reference specific products)
        enum Products {
            // Example: static let monthlyPro = "monthly_pro"
            // Example: static let annualPro = "annual_pro"
        }
    }
}
