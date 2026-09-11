import Foundation
import Supabase

// MARK: - Moderazione (Social feed M2)

/// Il blocco utenti che le regole UGC di Apple esigono, lato client.
///
/// Il blocco passa dalla RPC `block_user`: la riga di `user_blocks` la riusa il server (lapide
/// che rivive, come il re-follow) e un trigger pota i follow nei due versi — niente che il
/// chiamante debba ricordarsi. Lo sblocco invece NON ha una RPC: è il soft delete client-synced
/// del ramo `user_blocks` di `apply_mutations`, e vive in `ListManager.unblockUser` accanto al
/// `blockUser` outbox che esiste già per le liste pubbliche.
extension SupabaseService {

    /// Una riga della lista "utenti bloccati": la riga di `user_blocks` più l'identità pubblica.
    ///
    /// `profile` è `nil` quando il bloccato ha il profilo privato o sparito: `public_profiles`
    /// non lo espone per contratto, e inventare un nome sarebbe peggio che dichiarare
    /// "profilo non disponibile" — il blocco resta vero e sbloccabile comunque.
    struct BlockedUser: Identifiable, Equatable {
        let blockId: String
        let blockedUserId: String
        let profile: PublicProfile?

        var id: String { blockId }
    }

    /// Blocca un utente via RPC `block_user`. Il server riusa l'eventuale lapide e il trigger
    /// tombstona i follow in entrambe le direzioni: qui non c'è stato locale da mantenere.
    func blockUser(userId: String) async throws {
        guard let client else { throw SupabaseError.notConfigured }
        _ = try await client
            .rpc("block_user", params: ["p_user_id": userId])
            .execute()
    }

    /// L'id della riga attiva di `user_blocks` verso `userId`, se esiste.
    ///
    /// Serve allo sblocco: il ramo DELETE di `apply_mutations` lavora per id riga, e i blocchi
    /// fatti via RPC (`block_user`, `block_list_owner`) nello specchio locale non esistono —
    /// solo il server conosce quell'id. La RLS (`blocks_select_own`) mostra solo i propri
    /// blocchi, quindi nessun filtro su `user_id` da ricordare qui.
    func activeBlockId(against userId: String) async throws -> String? {
        guard let client else { throw SupabaseError.notConfigured }

        struct Row: Decodable {
            let id: String
        }

        let rows: [Row] = try await client
            .from("user_blocks")
            .select("id")
            .eq("blocked_user_id", value: userId)
            .is("deleted_at", value: nil)
            .limit(1)
            .execute()
            .value
        return rows.first?.id
    }

    /// Gli utenti bloccati, dal server e non dallo specchio locale.
    ///
    /// Lo specchio conosce solo i blocchi accodati da QUESTO client via outbox; quelli passati
    /// dalle RPC scrivono direttamente in produzione e in locale non lasciano traccia (la
    /// tabella non è nel pull). L'identità arriva da `public_profiles` con una seconda select:
    /// è la stessa superficie pubblica di `search_users`, quindi niente email né campi privati
    /// per costruzione.
    func fetchBlockedUsers() async throws -> [BlockedUser] {
        guard let client else { throw SupabaseError.notConfigured }

        struct BlockRow: Decodable {
            let id: String
            let blocked_user_id: String
        }

        let blocks: [BlockRow] = try await client
            .from("user_blocks")
            .select("id,blocked_user_id,created_at")
            .is("deleted_at", value: nil)
            .order("created_at", ascending: false)
            .execute()
            .value

        guard !blocks.isEmpty else { return [] }

        struct ProfileRow: Decodable {
            let id: String
            let username: String
            let display_name: String?
            let avatar_url: String?
        }

        let profiles: [ProfileRow] = try await client
            .from("public_profiles")
            .select("id,username,display_name,avatar_url")
            .in("id", values: blocks.map(\.blocked_user_id))
            .execute()
            .value
        let profilesById = Dictionary(profiles.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })

        return blocks.map { block in
            BlockedUser(
                blockId: block.id,
                blockedUserId: block.blocked_user_id,
                profile: profilesById[block.blocked_user_id].map {
                    PublicProfile(id: $0.id, username: $0.username,
                                  displayName: $0.display_name, avatarUrl: $0.avatar_url)
                }
            )
        }
    }
}
