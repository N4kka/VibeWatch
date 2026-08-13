import Foundation

/// Cosa promette il Pro, detto in un posto solo.
///
/// I due paywall raccontavano due storie diverse: `ProPaywallView` leggeva le chiavi
/// `paywall.feature.*` localizzate, mentre il paywall del limite giornaliero aveva le sue
/// stringhe scritte a mano **in inglese** — e quindi in inglese le leggevano tutti, nelle altre
/// 18 lingue comprese. Due delle tre promettevano anche cose che non esistono ("Early feature
/// access") o che non sono del Pro ("Personalized watchlists").
///
/// Una promessa commerciale su un abbonamento va detta una volta, in una lingua che l'utente
/// capisce, e deve corrispondere a un `isPro` che esiste davvero nel codice. Ogni chiave qui
/// sotto ha il suo gate: clip illimitati (`EntitlementPolicy.clipsDailyLimit`), niente pubblicità
/// (`shouldShowAds`), 100 liste (`maxCustomLists`), filtri avanzati (`GlobalFilterView`), offline
/// (`DailyContentPrefetchService`), 20 chat AI al giorno (`AppConstants.AI`).
enum PaywallCopy {

    /// L'elenco completo, nel paywall principale.
    static let proFeatureKeys = [
        "paywall.feature.aiAssistant",
        "paywall.feature.unlimitedClips",
        "paywall.feature.offlineMode",
        "paywall.feature.lists",
        "paywall.feature.advancedFilters",
        "paywall.feature.noAds"
    ]

    /// I tre argomenti quando l'utente ha appena finito i clip della giornata.
    static let clipsQuotaKeys = [
        "paywall.feature.unlimitedClips",
        "paywall.feature.noAds",
        "paywall.feature.lists"
    ]

    /// I tre argomenti quando ha finito le chat con Vibe AI.
    static let aiQuotaKeys = [
        "ai.paywall.benefit.unlimited",
        "ai.paywall.benefit.smarter",
        "ai.paywall.benefit.personalized"
    ]

    /// La stringa localizzata senza l'emoji iniziale: dove c'è già un'icona accanto, l'emoji
    /// diventa un secondo simbolo che dice la stessa cosa.
    static func plain(_ key: String) -> String {
        let localized = key.localized
        return String(localized.drop(while: { !($0.isLetter || $0.isNumber) }))
    }
}
