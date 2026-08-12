import Foundation

/// Chi firma la card condivisa: lo username del proprietario.
///
/// Lo specchio locale di `profiles` non ha lo username (v. ProfileView), quindi la prima card
/// di una sessione paga una lettura di rete; le successive leggono da qui. La cache è legata
/// all'id utente: un logout/login con un altro account non deve firmare le card col nome
/// sbagliato. Senza rete si ripiega sul display name: una card con una firma imprecisa è
/// comunque meglio di un tap che non produce niente.
@MainActor
enum ShareCardIdentity {
    private static var cached: (userId: String, username: String)?

    static func username() async -> String {
        let userId = SupabaseService.shared.currentUser?.id
        if let cached, cached.userId == userId { return cached.username }

        if let state = try? await SupabaseService.shared.usernameState(),
           let username = state.username, !username.isEmpty {
            if let userId { cached = (userId, username) }
            return username
        }
        // I 19 profili del backfill senza username, o la rete assente: il display name locale.
        return AppState.shared.currentUser?.displayName ?? ""
    }
}
