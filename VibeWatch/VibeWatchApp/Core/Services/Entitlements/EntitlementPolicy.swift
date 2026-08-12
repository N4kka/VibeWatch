import Foundation

/// Tier dell'utente per le decisioni di entitlement (quote/paywall/ads).
/// Deriva da RevenueCat (Pro) e dallo stato di autenticazione (anonimo vs loggato).
enum UserTier {
    case anonymous   // non loggato
    case free        // loggato, senza Pro
    case pro         // entitlement RevenueCat attivo
}

/// Policy PURA di entitlement — fonte unica di limiti e decisioni per tier (clip, liste, AI),
/// prima sparsa/duplicata tra `DailyQuotaManager`, `ClipQuotaService`, `AITokenManager` e
/// `ListManager` (col limite clip `25` hard-coded in due punti). È il nucleo della
/// consolidazione verso un EntitlementService unico (§1.3): i manager esistenti delegano qui,
/// comportamento preservato. Side-effect (persistenza, RevenueCat) restano nei manager.
/// Esito unificato della richiesta di guardare una clip (fonde il booleano can-watch col
/// gate da mostrare). È la forma che il futuro `EntitlementService` esporrà.
enum ClipAllowance: Equatable {
    case allowed         // può guardare
    case gateAccount     // anonimo esaurito → schermata crea-account
    case paywall         // free esaurito → paywall Pro
}

enum EntitlementPolicy {

    // MARK: - Derivazione tier (fonte unica)

    /// Deriva il tier dallo stato Pro (RevenueCat) e di autenticazione.
    /// Centralizza la logica `isPro ? .pro : (loggato ? .free : .anonymous)` oggi ripetuta inline.
    static func tier(isPro: Bool, isAuthenticated: Bool) -> UserTier {
        if isPro { return .pro }
        return isAuthenticated ? .free : .anonymous
    }

    // MARK: - Clip quota giornaliera

    /// Limite clip/giorno per tier. `nil` = illimitato (Pro).
    static func dailyClipLimit(for tier: UserTier) -> Int? {
        switch tier {
        case .anonymous, .free: return AppConstants.Clips.freeUserDailyLimit
        case .pro: return nil
        }
    }

    /// Può guardare un'altra clip oggi?
    static func canConsumeClip(tier: UserTier, clipsWatched: Int) -> Bool {
        guard let limit = dailyClipLimit(for: tier) else { return true } // Pro: illimitato
        return clipsWatched < limit
    }

    /// Clip rimanenti oggi (`Int.max` per Pro).
    static func remainingClips(tier: UserTier, clipsWatched: Int) -> Int {
        guard let limit = dailyClipLimit(for: tier) else { return Int.max }
        return max(0, limit - clipsWatched)
    }

    /// Gate da mostrare quando la quota clip è esaurita; `nil` se l'utente può ancora guardare.
    /// Anonimo esaurito → crea account; free esaurito → paywall Pro; Pro → mai.
    static func gate(tier: UserTier, clipsWatched: Int) -> ClipGateType? {
        guard !canConsumeClip(tier: tier, clipsWatched: clipsWatched) else { return nil }
        switch tier {
        case .anonymous: return .accountCreation
        case .free, .pro: return .proPaywall
        }
    }

    /// Esito unificato (allowed / gateAccount / paywall) per la richiesta di una clip.
    static func clipAllowance(tier: UserTier, clipsWatched: Int) -> ClipAllowance {
        switch gate(tier: tier, clipsWatched: clipsWatched) {
        case .none: return .allowed
        case .accountCreation: return .gateAccount
        case .proPaywall: return .paywall
        }
    }

    // MARK: - Richieste AI giornaliere

    /// Limite richieste AI/giorno per tier (Free/anonimo 5, Pro 10).
    static func aiDailyLimit(for tier: UserTier) -> Int {
        switch tier {
        case .anonymous, .free: return AppConstants.AI.freeDailyRequestLimit
        case .pro: return AppConstants.AI.proDailyRequestLimit
        }
    }

    static func canConsumeAIRequest(tier: UserTier, requestsUsed: Int) -> Bool {
        requestsUsed < aiDailyLimit(for: tier)
    }

    // MARK: - Liste custom

    /// Numero massimo di liste custom per tier (anonimo 0 — richiede comunque login, Free 2, Pro 100).
    static func maxCustomLists(for tier: UserTier) -> Int {
        switch tier {
        case .anonymous: return 0
        case .free: return ListManager.freeMaxCustomLists
        case .pro: return ListManager.proMaxCustomLists
        }
    }

    // MARK: - Ads

    /// Gli annunci si mostrano solo ai non-Pro.
    static func shouldShowAds(for tier: UserTier) -> Bool {
        tier != .pro
    }
}
