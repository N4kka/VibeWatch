import Foundation

struct NotificationPreferences: Codable {
    var enableNewAvailability: Bool = true
    var enableNewRelease: Bool = true
    var enableEpisodeAired: Bool = true
    var enableContinueWatching: Bool = true
    var enableListMilestone: Bool = true

    var maxDailyNotifications: Int = 3
    var quietHoursStart: Int = 22
    var quietHoursEnd: Int = 8
}

enum NotificationType: String, Codable {
    case newAvailability = "new_availability"
    case newRelease = "new_release"
    case episodeAired = "episode_aired"
    case continueWatching = "continue_watching"
    case listMilestone = "list_milestone"
    case priceDrop = "price_drop"
}
