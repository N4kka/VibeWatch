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
        /// Daily CHAT request allowance by tier. Counts only Vibe AI chat messages: the other AI
        /// features (why-for-me, loglines, ...) live in a separate "aux" bucket owned by the
        /// cerebras-proxy. Must stay in sync with supabase/functions/cerebras-proxy/quota.ts.
        static let proDailyRequestLimit = 20
        static let freeDailyRequestLimit = 8
    }
    
    enum Debug {
        /// Set to true while developing to force Pro mode (skips entitlement check)
        static let forceProUser = false
    }

    /// Google AdMob configuration
    enum AdMob {
        #if DEBUG
        /// Google's test banner ad unit ID for development
        static let bannerAdUnitID = "ca-app-pub-3940256099942544/2435281174"
        /// Google's test interstitial ad unit ID for development
        static let interstitialAdUnitID = "ca-app-pub-3940256099942544/4411468910"
        #else
        /// Production banner ad unit ID
        static let bannerAdUnitID = "ca-app-pub-7584278391945422/4228606699"
        /// Production interstitial ad unit ID
        static let interstitialAdUnitID = "ca-app-pub-7584278391945422/4313201322"
        #endif

        /// Show interstitial ad every N clips for free users
        static let clipsPerInterstitial = 5
    }
    
    /// RevenueCat subscription and entitlement identifiers
    enum RevenueCat {
        /// The entitlement identifier for Pro features
        /// This must match the entitlement configured in RevenueCat dashboard
        static let proEntitlementID = "StartingVibe Pro"
        
        /// Offering identifiers
        enum Offerings {
            static let standard = "default"
        }
        
        /// Product identifiers (if you need to reference specific products)
        enum Products {
            // Example: static let monthlyPro = "monthly_pro"
            // Example: static let annualPro = "annual_pro"
        }
    }
}
