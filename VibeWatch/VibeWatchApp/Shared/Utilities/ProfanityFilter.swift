import Foundation

/// Filtro parolacce minimale per i contenuti generati dagli utenti (nomi/descrizioni delle liste
/// pubbliche). Requisito moderazione App Store 1.2. Pura e testabile; volutamente conservativa
/// (match su parola intera, case/diacritics-insensitive) per ridurre i falsi positivi.
enum ProfanityFilter {
    /// Lista base EN/IT. Non esaustiva: prima linea di difesa lato client, affiancata da
    /// segnalazione utente + auto-hide server-side.
    static let blocklist: Set<String> = [
        // EN
        "fuck", "shit", "bitch", "cunt", "asshole", "nigger", "faggot", "rape", "whore", "slut",
        // IT
        "merda", "stronzo", "stronza", "puttana", "troia", "vaffanculo", "cazzo", "figa", "negro", "frocio"
    ]

    /// True se il testo contiene una parola della blocklist (match su token, non substring,
    /// per evitare lo "Scunthorpe problem").
    static func containsProfanity(_ text: String) -> Bool {
        let normalized = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let tokens = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for token in tokens where blocklist.contains(token) {
            return true
        }
        return false
    }

    /// Valida nome+descrizione di una lista da pubblicare. `nil` = ok, altrimenti chiave errore.
    static func validateForPublishing(name: String, description: String?) -> Bool {
        if containsProfanity(name) { return false }
        if let description, containsProfanity(description) { return false }
        return true
    }
}
