import Foundation

/// Chi firma la card condivisa, e a quale indirizzo risponde.
///
/// Lo specchio locale di `profiles` non ha lo username (v. ProfileView), quindi la prima card
/// di una sessione paga una lettura di rete; le successive leggono da qui. La cache è legata
/// all'id utente: un logout/login con un altro account non deve firmare le card col nome
/// sbagliato. Senza rete si ripiega sul display name: una card con una firma imprecisa è
/// comunque meglio di un tap che non produce niente.
///
/// **Il link esiste solo con uno username vero.** Il ripiego sul display name serve a firmare,
/// non a indirizzare: `vibewatchapp.com/@Mario Rossi` non è un URL, è una promessa rotta stampata
/// dentro un'immagine che poi gira su Instagram. Quando lo username manca (i 19 profili del
/// backfill, o la rete assente) la card mostra la sola firma e non offre nessun indirizzo.
@MainActor
enum ShareCardIdentity {

    struct Identity {
        /// Ciò che si stampa dopo la chiocciola: username vero o display name di ripiego.
        let handle: String
        /// L'indirizzo pubblico del profilo, `nil` senza username vero.
        let profileURL: URL?

        /// La forma leggibile da disegnare sulla card: chi la vede in una storia non può
        /// toccarla, ma può leggerla e digitarla. Senza indirizzo resta la sola firma.
        var drawnLink: String? {
            profileURL == nil ? nil : "\(UniversalLinks.host)/@\(handle)"
        }

        /// L'identità di un altro utente (la card di una lista altrui): lo username arriva dal
        /// server, quindi l'indirizzo è sempre costruibile.
        static func other(username: String) -> Identity {
            Identity(handle: username, profileURL: UniversalLinks.profileURL(username: username))
        }
    }

    private static var cached: (userId: String, identity: Identity)?

    static func current() async -> Identity {
        let userId = SupabaseService.shared.currentUser?.id
        if let cached, cached.userId == userId { return cached.identity }

        if let state = try? await SupabaseService.shared.usernameState(),
           let username = state.username, !username.isEmpty {
            let identity = Identity.other(username: username)
            if let userId { cached = (userId, identity) }
            return identity
        }
        // I 19 profili del backfill senza username, o la rete assente: firma sì, indirizzo no.
        // Non si mette in cache: è uno stato transitorio, e al prossimo tentativo con rete lo
        // username potrebbe esserci.
        return Identity(handle: AppState.shared.currentUser?.displayName ?? "", profileURL: nil)
    }

    static func username() async -> String {
        await current().handle
    }
}
