import Foundation

/// Tier dell'utente per le decisioni di entitlement (quote/paywall/ads).
/// Deriva da RevenueCat (Pro) e dallo stato di autenticazione (anonimo vs loggato).
enum UserTier {
    case anonymous   // non loggato
    case free        // loggato, senza Pro
    case pro         // entitlement RevenueCat attivo
}

/// Policy PURA per la quota clip giornaliera — fonte unica di limiti e decisioni,
/// prima duplicata tra `DailyQuotaManager` (free/pro) e `ClipQuotaService` (anonymous),
/// col limite `25` hard-coded in due punti (qui deriva da `AppConstants`).
///
/// Primo passo della consolidazione verso un EntitlementService unico (§1.3): la logica
/// di decisione è estratta e testabile; i manager esistenti delegano, comportamento preservato.
enum ClipEntitlementPolicy {

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

    /// Gate da mostrare quando la quota è esaurita; `nil` se l'utente può ancora guardare.
    /// Anonimo esaurito → crea account; free esaurito → paywall Pro; Pro → mai.
    static func gate(tier: UserTier, clipsWatched: Int) -> ClipGateType? {
        guard !canConsumeClip(tier: tier, clipsWatched: clipsWatched) else { return nil }
        switch tier {
        case .anonymous: return .accountCreation
        case .free, .pro: return .proPaywall
        }
    }
}
