import Foundation

/// Where notification preferences live on the device.
///
/// This used to be a pair of `static` methods on `NotificationPreferencesView`, which meant
/// `NotificationService` — a Core service — reached into a Feature view type to read a
/// UserDefaults blob. The storage is the same; only the ownership changed.
///
/// The key moved from `_v2` to `_v3` because the shape did: `enableListMilestone` and the
/// decorative `maxDailyNotifications` are gone, `enableStreakReminder` arrived defaulting to off.
/// Decoding v2 as v3 would silently keep the old daily-limit number and leave the streak toggle
/// at whatever `decodeIfPresent` defaulted to, so the migration is explicit and runs once.
enum NotificationPreferencesStore {
    private static let defaultsKey = "notificationPreferences_v3"
    private static let legacyKey = "notificationPreferences_v2"

    static func load() -> NotificationPreferences {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: defaultsKey),
           let prefs = try? JSONDecoder().decode(NotificationPreferences.self, from: data) {
            return prefs
        }

        if let migrated = migrateFromV2() {
            save(migrated)
            defaults.removeObject(forKey: legacyKey)
            return migrated
        }

        return NotificationPreferences()
    }

    static func save(_ prefs: NotificationPreferences) {
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    /// Carries over the toggles that still exist. Everything the user actually chose survives;
    /// what does not survive is the milestone toggle (no producer ever existed for it) and the
    /// old daily limit, which the server never read — carrying over a number that was never in
    /// effect would silently change how many notifications people receive.
    private static func migrateFromV2() -> NotificationPreferences? {
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let legacy = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var prefs = NotificationPreferences()
        func bool(_ key: String, default fallback: Bool) -> Bool {
            (legacy[key] as? Bool) ?? fallback
        }

        prefs.enableNewAvailability = bool("enableNewAvailability", default: true)
        prefs.enableNewRelease = bool("enableNewRelease", default: true)
        prefs.enableEpisodeAired = bool("enableEpisodeAired", default: true)
        prefs.enableContinueWatching = bool("enableContinueWatching", default: true)
        prefs.enableNewFollower = bool("enableNewFollower", default: true)
        prefs.enableActivityLiked = bool("enableActivityLiked", default: true)
        prefs.enableActivityCommented = bool("enableActivityCommented", default: true)
        prefs.quietHoursStart = (legacy["quietHoursStart"] as? Int) ?? 22
        prefs.quietHoursEnd = (legacy["quietHoursEnd"] as? Int) ?? 8
        return prefs
    }
}
