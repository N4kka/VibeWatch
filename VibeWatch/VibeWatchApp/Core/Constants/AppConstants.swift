import Foundation
import CoreGraphics

enum AppConstants {
    enum Clips {
        static let freeUserDailyLimit = 15
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
}