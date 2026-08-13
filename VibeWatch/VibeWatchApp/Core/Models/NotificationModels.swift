import Foundation

struct NotificationPreferences: Codable {
    var enableNewAvailability: Bool = true
    var enableNewRelease: Bool = true
    var enableEpisodeAired: Bool = true
    var enableContinueWatching: Bool = true
    var enableListMilestone: Bool = true

    // Social feed M2: i tre interruttori sociali, specchio delle colonne server
    // new_follower / activity_liked / activity_commented (default true come sul server).
    var enableNewFollower: Bool = true
    var enableActivityLiked: Bool = true
    var enableActivityCommented: Bool = true

    var maxDailyNotifications: Int = 3
    var quietHoursStart: Int = 22
    var quietHoursEnd: Int = 8

    init() {}

    // Decodifica campo-per-campo con default: il JSON salvato in UserDefaults prima della M2
    // non ha le chiavi sociali, e col decode sintetizzato un `.keyNotFound` butterebbe TUTTE
    // le preferenze dell'utente (loadFromDefaults ripiega sul default a ogni chiave nuova).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enableNewAvailability = try container.decodeIfPresent(
            Bool.self, forKey: .enableNewAvailability) ?? true
        enableNewRelease = try container.decodeIfPresent(
            Bool.self, forKey: .enableNewRelease) ?? true
        enableEpisodeAired = try container.decodeIfPresent(
            Bool.self, forKey: .enableEpisodeAired) ?? true
        enableContinueWatching = try container.decodeIfPresent(
            Bool.self, forKey: .enableContinueWatching) ?? true
        enableListMilestone = try container.decodeIfPresent(
            Bool.self, forKey: .enableListMilestone) ?? true
        enableNewFollower = try container.decodeIfPresent(
            Bool.self, forKey: .enableNewFollower) ?? true
        enableActivityLiked = try container.decodeIfPresent(
            Bool.self, forKey: .enableActivityLiked) ?? true
        enableActivityCommented = try container.decodeIfPresent(
            Bool.self, forKey: .enableActivityCommented) ?? true
        maxDailyNotifications = try container.decodeIfPresent(
            Int.self, forKey: .maxDailyNotifications) ?? 3
        quietHoursStart = try container.decodeIfPresent(
            Int.self, forKey: .quietHoursStart) ?? 22
        quietHoursEnd = try container.decodeIfPresent(
            Int.self, forKey: .quietHoursEnd) ?? 8
    }
}

enum NotificationType: String, Codable {
    case newAvailability = "new_availability"
    case newRelease = "new_release"
    case episodeAired = "episode_aired"
    case continueWatching = "continue_watching"
    case listMilestone = "list_milestone"
    case priceDrop = "price_drop"
}
