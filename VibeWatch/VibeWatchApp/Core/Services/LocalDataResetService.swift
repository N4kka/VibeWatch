import Foundation

/// Cancella dal device tutto ciò che appartiene a un account, lasciando in piedi solo ciò che
/// appartiene al *device*.
///
/// Il DB SQLite non è mai stato l'unico posto dove finiscono i dati di un utente: cronologia di
/// ricerca recente, episodi visti, like alle clip, sessioni AI, filtri di Scopri e preferenze di
/// notifica vivono in UserDefaults, con chiavi globali e senza user_id. Finché il logout puliva il
/// solo database, quella roba passava intatta da un account all'altro sullo stesso device — gli
/// "ultimi visitati" della SearchView dell'account A restavano lì dopo il login con B.
///
/// La regola qui è esplicita e va tenuta tale: si elencano le chiavi **da cancellare**, non quelle
/// da salvare. Un wipe per esclusione avrebbe travolto anche gli store degli SDK di terze parti
/// (RevenueCat, PostHog, Firebase) che convivono negli stessi UserDefaults.
@MainActor
final class LocalDataResetService {
    static let shared = LocalDataResetService()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Chiavi

    /// Chiavi UserDefaults che appartengono all'account e non devono sopravvivere a un cambio
    /// utente. Ogni nuova chiave che contiene attività, gusti o cronologia va aggiunta qui.
    static let userScopedDefaultsKeys: [String] = [
        // Ricerca e navigazione
        "latestVisitedItems",

        // Tracking serie/episodi
        "vibewatch.seen_episodes",
        "vibewatch.seen_shows",

        // Clip
        "likedClips",
        "clipLikeCounts",
        "clip_quota_anonymous_clips_watched",
        "clip_quota_cached_pro_status",
        "cachedClips",
        "cachedClipsCount",
        "lastClipsPrefetchDate",

        // Chat AI
        "ai_chat_session_id",
        "ai_chat_pinned_sessions",
        "ai_chat_session_titles",

        // Liste e import
        "media_lists",
        "publicListsGuidelinesAccepted",
        "import.banner.dismissedJobs",

        // Scopri / personalizzazione
        "selectedProviderNames",
        "GlobalDiscoveryFilters",
        "lastDiscoveryRandomization",
        "lastDailyPrefetchDate",

        // Notifiche
        "notificationPreferences_v3",
        "notificationPreferences_v2",
        // Iscrizioni "Avvisami" già confermate: sono per-account nella chiave, ma restare qui
        // significherebbe che il nuovo utente trova bottoni già spenti sui titoli del vecchio.
        "enabledMediaAvailabilityAlerts",

        // Sync: un timestamp ereditato dall'account precedente farebbe partire il primo pull del
        // nuovo utente da una data che per lui non significa niente, saltando tutto lo storico.
        "SyncEngine.lastSyncTimestamp",
        "lastForegroundSyncTime",

        // Quota e stato Pro cachato
        "isProUser",
        "dailyClipsCount",
        "lastQuotaReset",

        // Residui delle vecchie versioni, ancora letti dai percorsi di migrazione
        "genreScores",
        "movieScores",
        "userEngagementData",
        "vibe_watch_ai_token_usage",

        // Il seed del catalogo vive nel DB, che qui viene ricreato vuoto: senza azzerare il flag
        // resterebbe "già popolato" con le tabelle vuote.
        "initialDataPopulated",
        "initialDataMigratedDate"
    ]

    /// Chiavi costruite a runtime (`prefisso` + id utente / id sfida): si cancellano per prefisso.
    static let userScopedDefaultsPrefixes: [String] = [
        "discovery_last_loaded_day_",
        "gamification.challenge."
    ]

    // MARK: - API

    /// Riporta il device allo stato "nessun dato di account": UserDefaults, database locale,
    /// cache e stato in memoria dei servizi singleton.
    ///
    /// Da chiamare al logout e prima di rendere visibile un utente diverso da quello a cui i dati
    /// locali appartengono — mai quando un utente anonimo trasforma i propri dati in un account
    /// nuovo, che è l'unico caso in cui la continuità è voluta.
    func wipeUserScopedData() async {
        Logger.info("[LocalDataReset] Wiping user-scoped local data")

        clearUserScopedDefaults()
        resetInMemoryServices()

        // Dopo la ricreazione del file il DB ha solo lo schema di createTables(): le migrazioni
        // tengono la versione in app_metadata, che è appena tornata a zero, quindi rigirano.
        SQLiteService.shared.resetDatabase()
        await DatabaseMigrationManager.shared.runMigrations()

        // Il catalogo clip di partenza è dato condiviso, non dell'utente: si ripopola subito,
        // fuori dal percorso di logout perché passa dalla rete.
        Task { await DatabaseMigrationService.shared.migrateInitialData() }

        NotificationCenter.default.post(name: .localUserDataDidReset, object: nil)

        Logger.info("[LocalDataReset] Local data wiped")
    }

    // MARK: - Dettagli

    func clearUserScopedDefaults() {
        for key in Self.userScopedDefaultsKeys {
            defaults.removeObject(forKey: key)
        }

        for key in defaults.dictionaryRepresentation().keys
        where Self.userScopedDefaultsPrefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// I singleton tengono in memoria ciò che hanno letto all'avvio: senza questo giro la
    /// cancellazione su disco resterebbe invisibile fino al riavvio del processo.
    private func resetInMemoryServices() {
        ListManager.shared.resetListsForLoggedOutUser()
        DailyQuotaManager.shared.resetQuota()
        DailyQuotaManager.shared.downgradeToFree()
        ClipQuotaService.shared.resetAll()
        ClipsService.shared.resetLocalLikes()
        EpisodeSeenManager.shared.resetLocalState()
        ContentCacheManager.shared.clearAllCaches()
        DiscoveryPersonalizationService.shared.clearMemoryCache()
        SyncEngine.shared.resetLocalSyncState()
    }
}
