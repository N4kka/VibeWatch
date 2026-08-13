import Foundation

/// How many push notifications a user is willing to receive in a rolling 24 hours.
///
/// The server used to apply a single hardcoded cap of 2 to everyone, and anything above it was
/// collapsed into one digest banner. The cap is now the user's own call: `essential` reproduces
/// the old behaviour and stays the default, `everything` switches the digest off entirely, so
/// each notification keeps its own banner and its own deep link.
enum DailyNotificationCap: Int, CaseIterable, Codable {
    case essential = 2
    case balanced = 5
    case everything = 0  // 0 means "no cap" on the server side

    var titleKey: String {
        switch self {
        case .essential:   return "notifications.cap.essential"
        case .balanced:    return "notifications.cap.balanced"
        case .everything:  return "notifications.cap.everything"
        }
    }

    var footerKey: String {
        switch self {
        case .essential:   return "notifications.cap.essentialFooter"
        case .balanced:    return "notifications.cap.balancedFooter"
        case .everything:  return "notifications.cap.everythingFooter"
        }
    }

    /// Anything the server might hold — an older build, a value set by hand — resolves to the
    /// nearest preset rather than leaving the picker with no selection.
    static func nearest(to storedValue: Int) -> DailyNotificationCap {
        if storedValue <= 0 { return .everything }
        return allCases
            .filter { $0 != .everything }
            .min(by: { abs($0.rawValue - storedValue) < abs($1.rawValue - storedValue) }) ?? .essential
    }
}

struct NotificationPreferences: Codable {
    var enableNewAvailability: Bool = true
    var enableNewRelease: Bool = true
    var enableEpisodeAired: Bool = true
    var enableContinueWatching: Bool = true

    /// Opt-in, and off by default. It used to fire at every user with a live streak who had not
    /// opened the app that day — on its own, 92% of everything the system produced.
    var enableStreakReminder: Bool = false

    // Social feed M2: i tre interruttori sociali, specchio delle colonne server
    // new_follower / activity_liked / activity_commented (default true come sul server).
    var enableNewFollower: Bool = true
    var enableActivityLiked: Bool = true
    var enableActivityCommented: Bool = true

    /// News about saved titles, once a day, only when there is any. Independent of push.
    var enableEmailDigest: Bool = true
    var enableWeeklyRecap: Bool = true

    var dailyCap: DailyNotificationCap = .essential
    var quietHoursStart: Int = 22
    var quietHoursEnd: Int = 8

    init() {}

    // Decodifica campo-per-campo con default: il JSON salvato in UserDefaults da una versione
    // precedente non ha le chiavi nuove, e col decode sintetizzato un `.keyNotFound` butterebbe
    // TUTTE le preferenze dell'utente (il caricamento ripiega sul default a ogni chiave nuova).
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
        enableStreakReminder = try container.decodeIfPresent(
            Bool.self, forKey: .enableStreakReminder) ?? false
        enableNewFollower = try container.decodeIfPresent(
            Bool.self, forKey: .enableNewFollower) ?? true
        enableActivityLiked = try container.decodeIfPresent(
            Bool.self, forKey: .enableActivityLiked) ?? true
        enableActivityCommented = try container.decodeIfPresent(
            Bool.self, forKey: .enableActivityCommented) ?? true
        enableEmailDigest = try container.decodeIfPresent(
            Bool.self, forKey: .enableEmailDigest) ?? true
        enableWeeklyRecap = try container.decodeIfPresent(
            Bool.self, forKey: .enableWeeklyRecap) ?? true
        dailyCap = try container.decodeIfPresent(
            DailyNotificationCap.self, forKey: .dailyCap) ?? .essential
        quietHoursStart = try container.decodeIfPresent(
            Int.self, forKey: .quietHoursStart) ?? 22
        quietHoursEnd = try container.decodeIfPresent(
            Int.self, forKey: .quietHoursEnd) ?? 8
    }
}
