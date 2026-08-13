import Foundation
import Supabase

@MainActor
class SupabaseService: ObservableObject {
    static let shared = SupabaseService()
    
    // Delegate to AuthService for the client and user state
    var client: SupabaseClient? {
        return AuthService.shared.client
    }
    
    var currentUser: User? {
        return AuthService.shared.currentUser
    }
    
    var isAuthenticated: Bool {
        return AuthService.shared.isAuthenticated
    }
    
    private init() {
        self.deviceId = DeviceIdentity.installation
    }

    private let localDB = SQLiteService.shared
    private let deviceId: String

    private func localDayKey(for date: Date = Date()) -> String {
        SupabaseSyncFormatting.localDayKey(for: date)
    }

    private func isDateInTodayLocal(_ date: Date) -> Bool {
        SupabaseSyncFormatting.isDateInTodayLocal(date)
    }

    private func normalizeUserId(_ userId: String) -> String {
        SupabaseSyncFormatting.normalizeUserId(userId)
    }

    private struct LocalAITokenUsageState {
        let tokens: Int
        let didResetForNewDay: Bool
    }

    /// Ensures the cached `user_ai_token_usage` row is for the current local day.
    /// Returns the corrected cached value (0 if it was reset).
    private func normalizeLocalAITokenUsageForToday(userId: String) async -> LocalAITokenUsageState? {
        let normalizedUserId = normalizeUserId(userId)
        let todayKey = localDayKey()

        do {
            let rows = try await localDB.queryRaw(
                "SELECT tokens_used_today, usage_day, updated_at FROM user_ai_token_usage WHERE user_id = ? LIMIT 1",
                parameters: [normalizedUserId]
            )
            guard let row = rows.first else { return nil }

            let tokens = row["tokens_used_today"] as? Int ?? 0
            let usageDay = row["usage_day"] as? String
            let updatedAt = parseDate(row["updated_at"])

            if let usageDay {
                if usageDay == todayKey {
                    return LocalAITokenUsageState(tokens: tokens, didResetForNewDay: false)
                }
            } else if let updatedAt, isDateInTodayLocal(updatedAt) {
                // Backfill day without resetting if the timestamp is still "today".
                let now = ISO8601DateFormatter().string(from: Date())
                let update: [String: Any] = [
                    "user_id": normalizedUserId,
                    "tokens_used_today": tokens,
                    "usage_day": todayKey,
                    "updated_at": now
                ]
                try? await localDB.upsert(table: "user_ai_token_usage", rows: [update])
                return LocalAITokenUsageState(tokens: tokens, didResetForNewDay: false)
            }

            // New day (or unknown): reset locally.
            await resetLocalAITokenUsage(userId: normalizedUserId)
            return LocalAITokenUsageState(tokens: 0, didResetForNewDay: true)
        } catch {
            Logger.warning("[SQLite] Failed to read cached AI token usage: \(error.localizedDescription)")
            return nil
        }
    }

    private func resetLocalAITokenUsage(userId: String) async {
        let normalizedUserId = normalizeUserId(userId)
        let now = ISO8601DateFormatter().string(from: Date())
        let todayKey = localDayKey()
        let row: [String: Any] = [
            "user_id": normalizedUserId,
            "tokens_used_today": 0,
            "usage_day": todayKey,
            "updated_at": now
        ]
        do {
            try await localDB.upsert(table: "user_ai_token_usage", rows: [row])
            NotificationCenter.default.post(name: .aiTokenUsageDidReset, object: nil)
            Logger.debug("[SQLite] Reset cached AI tokens for user \(normalizedUserId) (day=\(todayKey))")
        } catch {
            Logger.warning("[SQLite] Failed to reset cached AI token usage locally: \(error.localizedDescription)")
        }
    }

    /// Best-effort: reset the remote `user_ai_token_usage` row to 0 (used when local midnight passes).
    private func resetRemoteAITokenUsageIfPossible(userId: String) async {
        guard let client else { return }

        // Goes through the reset_ai_token_usage RPC rather than a table update: the previous direct
        // .update() sent tokens_used_today (a local-only column; the remote schema uses
        // total_tokens_used) and could not create today's row at all, since the table has no INSERT
        // RLS policy. The RPC upserts under SECURITY DEFINER and only touches the caller's own row.
        guard let uuid = UUID(uuidString: normalizeUserId(userId)) else {
            Logger.warning("[Supabase] Skipping remote AI token reset: invalid user id \(userId)")
            return
        }

        struct ResetRequest: Encodable {
            let p_user_id: UUID
        }

        do {
            try await client.rpc("reset_ai_token_usage", params: ResetRequest(p_user_id: uuid)).execute()
        } catch {
            // Ignore: offline / RLS / schema differences should not break local quota behavior.
            Logger.warning("[Supabase] Failed to reset remote AI token usage: \(error.localizedDescription)")
        }
    }

    /// Called by app-level day-change handlers to enforce local-midnight reset.
    func handleLocalDayBoundaryForCurrentUser() async {
        guard let userId = currentUser?.id else { return }
        let normalized = normalizeUserId(userId)
        let state = await normalizeLocalAITokenUsageForToday(userId: normalized)
        if state?.didResetForNewDay == true {
            await resetRemoteAITokenUsageIfPossible(userId: normalized)
        }
    }
    
    private enum PullConflictPolicy {
        case serverWins
        case lastModified
    }

    private func conflictPolicy(for table: String) -> PullConflictPolicy {
        switch table {
        case "lists", "list_items", "user_preferences", "profiles":
            return .lastModified
        default:
            return .serverWins
        }
    }

    private func parseDate(_ value: Any?) -> Date? {
        SupabaseSyncFormatting.parseDate(value)
    }

    // MARK: - Clip Signals

    func logClipSignal(
        clipId: String,
        signalType: String,
        signalValue: Double,
        context: AnalyticsContext? = nil
    ) async {
        guard let userId = currentUser?.id else { return }

        let recordId = UUID().uuidString.lowercased()
        let now = ISO8601DateFormatter().string(from: Date())

        let values: [String: Any] = [
            "id": recordId,
            "user_id": userId,
            "device_id": deviceId,
            "clip_id": clipId,
            "signal_type": signalType,
            "signal_value": signalValue,
            "source": context?.source ?? NSNull(),
            "position": context?.position ?? NSNull(),
            "session_id": context?.sessionId ?? NSNull(),
            "occurred_at": now,
            "synced_at": NSNull()
        ]

        do {
            _ = try await localDB.insert("user_clip_signals", values: values)
            try await SyncEngine.shared.queueOperation(
                table: "user_clip_signals",
                operationType: "INSERT",
                recordId: recordId,
                payload: values,
                dependsOn: nil
            )
        } catch {
            Logger.error("[Supabase] Failed to log clip signal", error: error)
        }
    }

    /// Check if the remote row is newer than local (by updated_at). If no local row, treat as newer.
    private func isRemoteNewer(table: String, id: String, remoteUpdatedAt: Date?) async -> Bool {
        guard let remoteUpdatedAt else { return true }
        do {
            let rows = try await localDB.queryRaw("SELECT updated_at FROM \(table) WHERE id = ? LIMIT 1", parameters: [id])
            guard let localUpdatedRaw = rows.first?["updated_at"] else { return true }
            if let localDate = parseDate(localUpdatedRaw) {
                return remoteUpdatedAt > localDate
            }
            return true
        } catch {
            return true
        }
    }

    // MARK: - Generic pull helper (stub for automated sync)
    /// Fetch latest rows for a table, optionally filtered by user_id, and upsert into local DB.
    func pullTable(name: String, userId: String?) async throws {
        guard let client else {
            throw SupabaseError.notConfigured
        }
        
        var query = client.from(name).select("*")
        if let userId {
            if name == "profiles" {
                query = query.eq("id", value: userId) // profiles table uses id, not user_id
            } else {
                query = query.eq("user_id", value: userId)
            }
        }
        
        let data = try await query.execute().data

        // Decode raw JSON into [String: Any]
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        // Normalize rows per table (media_type, JSON fields)
        let normalized = rows.map { SupabasePullRowNormalizer.normalize(row: $0, table: name) }

        // Conflict handling
        let policy = conflictPolicy(for: name)
        var rowsToUpsert: [[String: Any]] = []

        switch policy {
        case .serverWins:
            rowsToUpsert = normalized
        case .lastModified:
            for row in normalized {
                guard let idAny = row["id"] else { continue }
                let idString = String(describing: idAny)
                let remoteDate = parseDate(row["updated_at"])
                let newer = await isRemoteNewer(table: name, id: idString, remoteUpdatedAt: remoteDate)
                if newer {
                    rowsToUpsert.append(row)
                }
            }
        }

        try await SQLiteService.shared.upsert(table: name, rows: rowsToUpsert)
    }

    // MARK: - Push (batch) via RPC

    /// Applies a batch of mutations atomically using the `apply_mutations` RPC on Supabase.
    /// Each mutation should include: op ('INSERT'|'UPDATE'|'DELETE'), table, id, record (JSON object).
    /// - Parameter allowClientSideFallback: quando l'RPC risponde male si ripiega su una upsert
    ///   REST per riga. Per le scritture normali e' la rete di sicurezza giusta; per un lotto va
    ///   spento. Il ripiego fa una chiamata per record e, soprattutto, risolve i conflitti su `id`
    ///   invece che su `dedup_key`: un rigioco della migrazione dello storico genererebbe id nuovi
    ///   e andrebbe a sbattere sull'indice unico di `watch_events` una riga alla volta, invece di
    ///   essere il caso normale che `apply_mutations` gestisce saltando cio' che c'e' gia'.
    func applyMutations(
        _ batch: [[String: Any]],
        allowClientSideFallback: Bool = true
    ) async throws {
        guard client != nil else {
            throw SupabaseError.notConfigured
        }
        // Manually call RPC endpoint to avoid Encodable/Any issues
        guard let baseURL = URL(string: Config.supabaseURL) else {
            throw SupabaseError.notConfigured
        }
        let url = baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent("rpc")
            .appendingPathComponent("apply_mutations")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let client,
           let session = try? await client.auth.session {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        } else if Config.supabaseAnonKey.hasPrefix("eyJ") {
            // Legacy anon key is a JWT and is valid in the Authorization header. New publishable
            // keys (sb_publishable_...) are NOT JWTs — the API gateway rejects them here as
            // "Invalid JWT", so when using one we send it only via the apikey header.
            request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        }

        let body = try JSONSerialization.data(withJSONObject: ["batch": batch], options: [])
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }

        if (200...299).contains(http.statusCode) {
            return
        }

        let bodyString = String(data: data, encoding: .utf8) ?? ""

        // If the RPC isn't deployed yet, fall back to client-side REST operations.
        if allowClientSideFallback,
           http.statusCode == 404 || bodyString.lowercased().contains("apply_mutations") {
            try await applyMutationsClientSide(batch)
            return
        }

        throw SupabaseError.httpError(statusCode: http.statusCode, body: bodyString)
    }

    // MARK: - Preferences RPC

    func mergeUserPreferences(userId: UUID, preferences: [[String: Any]]) async throws -> [String: Any] {
        let payload: [String: Any] = [
            "p_user_id": userId.uuidString.lowercased(),
            "p_preferences": preferences
        ]

        let data = try await callRPC(function: "merge_user_preferences", payload: payload)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Migrazione dello storico (SPEC v3 blocco 7)

    /// Espande le serie marcate "viste per intero" negli episodi che il catalogo conosce.
    ///
    /// L'espansione sta server-side perche' li' c'e' il catalogo (§1.4): il client sa *che* la
    /// serie e' vista tutta, non *quali* episodi la compongono. Ritorna quante righe sono nate e
    /// quali serie non erano espandibili perche' il catalogo non le ha ancora.
    func expandSeenShowsToWatchEvents(
        _ shows: [[String: Any]]
    ) async throws -> LegacyExpansionOutcome {
        let data = try await callRPC(
            function: "expand_seen_shows_to_watch_events", payload: ["p_shows": shows])
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return LegacyExpansionOutcome(
            eventsWritten: json?["events_written"] as? Int ?? 0,
            showsWithoutCatalog: json?["shows_without_catalog"] as? [Int] ?? []
        )
    }

    /// Fusione ListsView-Tracking: toglie una serie dalla lista Seen — lapide su tutti i suoi
    /// eventi + `dropped`, in un'unica RPC server (`unsee_tv_show`). Ritorna quanti eventi hanno
    /// preso la lapide: zero e' un esito legittimo (rigiocata), non un errore.
    func unseeTVShow(showId: Int) async throws -> Int {
        let data = try await callRPC(
            function: "unsee_tv_show", payload: ["p_tmdb_show_id": showId])
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["events_removed"] as? Int ?? 0
    }

    /// Popola `tmdb_shows`/`tmdb_episodes` per serie gia' identificate su TMDB.
    ///
    /// Passa da `catalog-resolve` e non da TMDB diretto: la chiave sta server-side, il budget e'
    /// li', e il catalogo e' condiviso fra tutti gli utenti (§1.5) — la serie riscaldata da uno la
    /// trovano pronta gli altri. Serve un JWT utente, non la chiave anonima.
    func warmCatalog(showIds: [Int]) async throws {
        guard !showIds.isEmpty else { return }
        guard let url = URL(string: Config.supabaseURL.replacingOccurrences(
            of: ".supabase.co", with: ".functions.supabase.co") + "/catalog-resolve")
        else { throw SupabaseError.notConfigured }

        guard let client, let session = try? await client.auth.session else {
            throw SupabaseError.notAuthenticated
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["show_ids": showIds])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.networkError }
        guard (200...299).contains(http.statusCode) else {
            throw SupabaseError.httpError(
                statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - Username (SPEC v3 §3.7)

    /// Lo stato dello username del proprietario: qual è, e se l'ha mai confermato.
    ///
    /// `username_confirmed_at` nullo significa "assegnato dal backfill e mai visto da chi lo
    /// porta": è il segnale che fa comparire la schermata di scelta. Un `username` nullo significa
    /// che il nome non era derivabile — sono 19 profili — e per quelli la schermata non è una
    /// conferma ma l'unico modo di comparire in `public_profiles`.
    func usernameState() async throws -> (username: String?, confirmed: Bool)? {
        guard let client, let userId = currentUser?.id else { throw SupabaseError.notAuthenticated }

        struct Row: Decodable {
            let username: String?
            let usernameConfirmedAt: Date?
            enum CodingKeys: String, CodingKey {
                case username
                case usernameConfirmedAt = "username_confirmed_at"
            }
        }

        let rows: [Row] = try await client
            .from("profiles")
            .select("username,username_confirmed_at")
            .eq("id", value: userId)
            .limit(1)
            .execute()
            .value

        guard let row = rows.first else { return nil }
        return (row.username, row.usernameConfirmedAt != nil)
    }

    /// I dati modificabili del proprio profilo. La lettura diretta della riga è intenzionale:
    /// `public_profiles` nasconde correttamente un profilo privato anche al suo proprietario.
    func ownProfileDetails() async throws -> OwnProfileDetails? {
        guard let client, let userId = currentUser?.id else { throw SupabaseError.notAuthenticated }

        let rows: [OwnProfileDetails] = try await client
            .from("profiles")
            .select("username,display_name,avatar_url,bio,is_profile_public")
            .eq("id", value: userId)
            .limit(1)
            .execute()
            .value

        return rows.first
    }

    /// Salva i campi che non richiedono la procedura atomica di `set_username`.
    /// La bio ha anche un CHECK a 200 caratteri sul database; il limite UI non è l'unica difesa.
    func updateOwnProfileDetails(bio: String?, isProfilePublic: Bool) async throws {
        guard let client, let userId = currentUser?.id else { throw SupabaseError.notAuthenticated }

        struct Update: Encodable {
            let bio: String?
            let isProfilePublic: Bool

            enum CodingKeys: String, CodingKey {
                case bio
                case isProfilePublic = "is_profile_public"
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                if let bio {
                    try container.encode(bio, forKey: .bio)
                } else {
                    // `encodeIfPresent` ometterebbe la colonna e renderebbe impossibile
                    // cancellare una bio già salvata. Qui serve un NULL esplicito.
                    try container.encodeNil(forKey: .bio)
                }
                try container.encode(isProfilePublic, forKey: .isProfilePublic)
            }
        }

        try await client
            .from("profiles")
            .update(Update(bio: bio, isProfilePublic: isProfilePublic))
            .eq("id", value: userId)
            .execute()
    }

    /// Libero? Il server decide: qui non si può sapere se un nome è riservato.
    func usernameAvailable(_ username: String) async throws -> Bool {
        let data = try await callRPC(
            function: "username_available", payload: ["p_username": username])
        return try Self.parseBooleanRPCResponse(data)
    }

    /// Una funzione SQL che restituisce `boolean` arriva da PostgREST come `true`/`false` nudo:
    /// un frammento JSON di primo livello, che `jsonObject` senza `.fragmentsAllowed` rifiuta.
    /// Una risposta che non si capisce è un errore, non un "no": tradurla in `false` faceva
    /// rispondere "già preso" a ogni nome, compresi i liberi.
    static func parseBooleanRPCResponse(_ data: Data) throws -> Bool {
        guard let value = (try? JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed])) as? Bool else {
            throw SupabaseError.unexpectedResponse(
                body: String(data: data, encoding: .utf8) ?? "<non-UTF8>")
        }
        return value
    }

    /// Sceglie o conferma. Gli esiti "occupato" e "riservato" tornano come risposta, non come
    /// eccezione: in questa schermata sono la cosa più probabile che succeda.
    func setUsername(_ username: String) async throws -> SetUsernameOutcome {
        let data = try await callRPC(function: "set_username", payload: ["p_username": username])
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return SetUsernameOutcome(json: json)
    }

    // MARK: - Social (SPEC v3 §3.7 / §9.3)

    /// Ricerca utenti. Il server decide tutto: superficie pubblica, blocchi nei due versi, ordine.
    func searchUsers(_ query: String, limit: Int = 20) async throws -> [PublicProfile] {
        let data = try await callRPC(
            function: "search_users", payload: ["p_query": query, "p_limit": limit])
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw SupabaseError.unexpectedResponse(
                body: String(data: data.prefix(300), encoding: .utf8) ?? "<non-UTF8>")
        }
        return rows.compactMap(PublicProfile.init(json:))
    }

    /// Il profilo pubblico di §9.3, coi contatori e la relazione col chiamante.
    ///
    /// `nil` significa "non esiste" — che per scelta del server copre anche privato, cancellato,
    /// senza username e bloccato in uno dei due versi: che un blocco esista è privato.
    func publicProfile(username: String) async throws -> PublicProfileDetail? {
        let data = try await callRPC(
            function: "get_public_profile", payload: ["p_username": username])
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SupabaseError.unexpectedResponse(
                body: String(data: data.prefix(300), encoding: .utf8) ?? "<non-UTF8>")
        }
        return PublicProfileDetail(json: json)
    }

    /// Le stats di base di §9.3, calcolate dal server (§13.7): il client non somma niente.
    /// Una risposta illeggibile è un errore, mai un pannello di zeri.
    func myStats() async throws -> UserStats {
        let data = try await callRPC(function: "get_my_stats", payload: [:])
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stats = UserStats(json: json) else {
            throw SupabaseError.unexpectedResponse(
                body: String(data: data.prefix(300), encoding: .utf8) ?? "<non-UTF8>")
        }
        return stats
    }

    // MARK: - Import TV Time (SPEC v3 §7)

    /// Carica lo ZIP nella PROPRIA cartella del bucket `imports` e restituisce il path.
    /// Il nome è un UUID: due import successivi non si sovrascrivono, e il TTL del bucket
    /// (7 giorni, §7.2) porta via i vecchi.
    func uploadImportZip(_ data: Data) async throws -> String {
        guard let client, let userId = currentUser?.id else {
            throw SupabaseError.notAuthenticated
        }
        // La cache Keychain può dire "loggato" mentre la sessione GoTrue è morta da mesi:
        // meglio scoprirlo QUI, con un errore chiaro e lo stato auth riallineato, che
        // lasciare che la RLS respinga l'upload con "new row violates row-level security
        // policy". `client.auth.session` forza il refresh; se fallisce, checkAuthState
        // (che ora distingue rete da rifiuto) decide se è offline o sign-in da rifare.
        do {
            _ = try await client.auth.session
        } catch {
            await AuthService.shared.checkAuthState()
            throw SupabaseError.sessionExpired
        }
        // Minuscolo obbligatorio: la policy del bucket confronta la cartella con
        // auth.uid()::text (minuscolo), e un id cacheato può venire da `uuidString`
        // (MAIUSCOLO).
        let path = "\(userId.lowercased())/\(UUID().uuidString.lowercased()).zip"
        _ = try await client.storage
            .from("imports")
            .upload(path, data: data, options: .init(contentType: "application/zip"))
        return path
    }

    /// Crea il job sul proprio ZIP già caricato. Gli esiti prevedibili (`already_running`,
    /// `upload_not_found`…) tornano come risposta, non come eccezione: in questa schermata
    /// sono cose che succedono, non guasti.
    func createImportJob(storagePath: String) async throws -> ImportStartOutcome {
        let data = try await callRPC(
            function: "create_import_job", payload: ["p_storage_path": storagePath])
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let outcome = ImportStartOutcome(json: json) else {
            throw SupabaseError.unexpectedResponse(
                body: String(data: data.prefix(300), encoding: .utf8) ?? "<non-UTF8>")
        }
        return outcome
    }

    /// Riporta a `running` un proprio job `failed`. Checkpoint e `dedup_key` rendono la
    /// ripresa sicura lato server; qui c'è solo la chiamata.
    func retryImportJob(id: String) async throws -> ImportStartOutcome {
        let data = try await callRPC(function: "retry_import_job", payload: ["p_job_id": id])
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let outcome = ImportStartOutcome(json: json) else {
            throw SupabaseError.unexpectedResponse(
                body: String(data: data.prefix(300), encoding: .utf8) ?? "<non-UTF8>")
        }
        return outcome
    }

    /// L'ultimo job del chiamante, il più recente prima. La RLS mostra solo i propri;
    /// `nil` = mai fatto un import. Serve alla ripresa: la schermata riaperta deve ritrovare
    /// l'import in corso (o l'ultimo report), perché lo stato vive sul server (§7.2).
    func latestImportJob() async throws -> ImportJobSnapshot? {
        guard let client else { throw SupabaseError.notAuthenticated }
        let rows: [ImportJobSnapshot] = try await client
            .from("import_jobs")
            .select("id, phase, status, error, totals, created_at")
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Lo stato corrente di un job: è ciò che il polling legge. Il client non muove niente —
    /// le fasi sono del server — quindi qui c'è solo una SELECT sotto RLS.
    func importJob(id: String) async throws -> ImportJobSnapshot? {
        guard let client else { throw SupabaseError.notAuthenticated }
        let rows: [ImportJobSnapshot] = try await client
            .from("import_jobs")
            .select("id, phase, status, error, totals, created_at")
            .eq("id", value: id)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Redesign 2.0: esclude dall'inbox "Titoli da verificare" i titoli che l'utente ha scelto
    /// di lasciar perdere. La RPC (`import_exclude_unresolved`, security definer con controllo
    /// del proprietario) marca le righe di staging e il report smette di contarle.
    func excludeImportUnresolved(jobId: String, seriesIds: [String], movieUuids: [String],
                                 seriesTitles: [String]) async throws {
        var payload: [String: Any] = ["p_job_id": jobId]
        if !seriesIds.isEmpty { payload["p_tvdb_series_ids"] = seriesIds }
        if !movieUuids.isEmpty { payload["p_movie_uuids"] = movieUuids }
        if !seriesTitles.isEmpty { payload["p_series_titles"] = seriesTitles }
        let data = try await callRPC(function: "import_exclude_unresolved", payload: payload)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ok = json["ok"] as? Bool else {
            throw SupabaseError.unexpectedResponse(
                body: String(data: data.prefix(300), encoding: .utf8) ?? "<non-UTF8>")
        }
        // `nothing_to_exclude` non è un guasto: le righe erano già fuori (per esempio un
        // doppio tap, o un'esclusione arrivata da un altro device). Il report riletto farà fede.
        if !ok, (json["reason"] as? String) != "nothing_to_exclude" {
            throw SupabaseError.unexpectedResponse(
                body: (json["reason"] as? String) ?? "exclude_failed")
        }
    }

    /// §7.4: la risoluzione A MANO delle serie non riconosciute. Il server (Edge Function
    /// `import-manual-resolve`) salva tutte le mappe e riapre una sola volta il job in
    /// `resolving`, dove ogni episodio viene riconfermato tramite il suo ID TVDB esatto. Un errore HTTP
    /// arriva intero al chiamante — il corpo è la diagnosi (`series_already_mapped`,
    /// `nothing_to_resolve`, `another_job_open`, `staging_changed`…), e nasconderlo lascerebbe
    /// l'utente davanti a un pulsante che "non fa niente".
    func manualResolveImport(jobId: String,
                             resolutions: [ImportManualResolution]) async throws {
        guard let url = URL(string: Config.supabaseURL.replacingOccurrences(
            of: ".supabase.co", with: ".functions.supabase.co") + "/import-manual-resolve")
        else { throw SupabaseError.notConfigured }

        guard let client, let session = try? await client.auth.session else {
            throw SupabaseError.notAuthenticated
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "job_id": jobId,
            "resolutions": resolutions.map {
                ["tvdb_series_id": $0.tvdbSeriesId, "tmdb_show_id": $0.tmdbShowId] as [String: Any]
            },
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.networkError }
        guard (200...299).contains(http.statusCode) else {
            throw SupabaseError.httpError(
                statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Il report di §7.4, calcolato dal server (`import_report`, security invoker: decide la
    /// RLS). Una risposta illeggibile è un errore, mai un report di zeri.
    func importReport(jobId: String) async throws -> ImportReport {
        let data = try await callRPC(function: "import_report", payload: ["p_job_id": jobId])
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let report = ImportReport(json: json) else {
            throw SupabaseError.unexpectedResponse(
                body: String(data: data.prefix(300), encoding: .utf8) ?? "<non-UTF8>")
        }
        return report
    }

    private func callRPC(function: String, payload: [String: Any]) async throws -> Data {
        guard let baseURL = URL(string: Config.supabaseURL) else {
            throw SupabaseError.notConfigured
        }

        let url = baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent("rpc")
            .appendingPathComponent(function)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")

        if let client,
           let session = try? await client.auth.session {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        } else if Config.supabaseAnonKey.hasPrefix("eyJ") {
            // Legacy anon key is a JWT and is valid in the Authorization header. New publishable
            // keys (sb_publishable_...) are NOT JWTs — the API gateway rejects them here as
            // "Invalid JWT", so when using one we send it only via the apikey header.
            request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseError.httpError(statusCode: http.statusCode, body: body)
        }

        return data
    }

    // MARK: - Generic REST Upsert

    func upsertRow(
        table: String,
        onConflict: String,
        record: [String: Any]
    ) async throws {
        guard let baseURL = URL(string: Config.supabaseURL) else {
            throw SupabaseError.notConfigured
        }

        var components = URLComponents(url: baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent(table), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: onConflict)]

        guard let url = components?.url else {
            throw SupabaseError.networkError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")

        if let client,
           let session = try? await client.auth.session {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        } else if Config.supabaseAnonKey.hasPrefix("eyJ") {
            // Legacy anon key is a JWT and is valid in the Authorization header. New publishable
            // keys (sb_publishable_...) are NOT JWTs — the API gateway rejects them here as
            // "Invalid JWT", so when using one we send it only via the apikey header.
            request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: record, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseError.httpError(statusCode: http.statusCode, body: body)
        }
    }

    private func deleteRow(table: String, id: String) async throws {
        guard let baseURL = URL(string: Config.supabaseURL) else {
            throw SupabaseError.notConfigured
        }

        var components = URLComponents(url: baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent(table), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(id)")]

        guard let url = components?.url else {
            throw SupabaseError.networkError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        if let client,
           let session = try? await client.auth.session {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        } else if Config.supabaseAnonKey.hasPrefix("eyJ") {
            // Legacy anon key is a JWT and is valid in the Authorization header. New publishable
            // keys (sb_publishable_...) are NOT JWTs — the API gateway rejects them here as
            // "Invalid JWT", so when using one we send it only via the apikey header.
            request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.networkError
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseError.httpError(statusCode: http.statusCode, body: body)
        }
    }

    private func applyMutationsClientSide(_ batch: [[String: Any]]) async throws {
        for mutation in batch {
            let op = (mutation["op"] as? String)?.uppercased() ?? "UPSERT"
            guard let table = mutation["table"] as? String else { continue }
            let mutationId = mutation["id"] as? String
            var record = mutation["record"] as? [String: Any] ?? [:]

            if let mutationId, !mutationId.isEmpty, record["id"] == nil {
                record["id"] = mutationId
            }

            switch op {
            case "DELETE":
                if let id = (mutationId ?? record["id"] as? String), !id.isEmpty {
                    try await deleteRow(table: table, id: id)
                }
            default:
                try await upsertRow(table: table, onConflict: "id", record: record)
            }
        }
    }
    
    // MARK: - Lists
    
    func fetchLists() async throws -> [MediaList] {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        guard let userId = currentUser?.id else {
            throw SupabaseError.notAuthenticated
        }
        
        // Fetch lists
        struct SupabaseList: Codable {
            let id: String
            let name: String
            let description: String?
            let type: String
            let createdAt: Date
            
            enum CodingKeys: String, CodingKey {
                case id, name, description, type
                case createdAt = "created_at"
            }
        }
        
        let listsData: [SupabaseList] = try await client
            .from("lists")
            .select()
            .eq("user_id", value: userId)
            .is("deleted_at", value: nil)
            .order("created_at", ascending: true)
            .execute()
            .value
        
        // Fetch all lists' items in parallel
        let mediaLists: [MediaList] = try await withThrowingTaskGroup(of: MediaList.self) { group in
            for listData in listsData {
                group.addTask {
                    let items = try await self.fetchListItems(listId: listData.id)
                    let listType = ListType(databaseValue: listData.type) ?? ListType(rawValue: listData.type) ?? .custom
                    return MediaList(
                        id: listData.id,
                        name: listData.name,
                        description: listData.description,
                        type: listType,
                        createdAt: listData.createdAt,
                        items: items
                    )
                }
            }
            var results: [MediaList] = []
            for try await list in group {
                results.append(list)
            }
            return results
        }

        return mediaLists
    }
    
    func createList(id: String, name: String, description: String?, type: ListType) async throws -> MediaList {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        guard let userId = currentUser?.id else {
            throw SupabaseError.notAuthenticated
        }
        
        struct CreateListRequest: Encodable {
            let id: String  // Use our local ID
            let user_id: String
            let name: String
            let description: String?
            let type: String
        }
        
        struct CreateListResponse: Decodable {
            let id: String
            let name: String
            let description: String?
            let type: String
            let created_at: Date
        }
        
        
        let request = CreateListRequest(
            id: id,  // Pass our local ID
            user_id: userId,
            name: name,
            description: description,
            type: type.rawValue
        )
        
        let response: CreateListResponse = try await client
            .from("lists")
            .insert(request)
            .select()
            .single()
            .execute()
            .value
        
        return MediaList(
            id: response.id,
            name: response.name,
            description: response.description,
            type: type,
            createdAt: response.created_at,
            items: []
        )
    }
    
    func deleteList(id: String) async throws {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        try await client
            .from("lists")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    func updateList(id: String, name: String, description: String?) async throws {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        struct UpdateListRequest: Encodable {
            let name: String
            let description: String?
        }
        
        let request = UpdateListRequest(name: name, description: description)
        
        try await client
            .from("lists")
            .update(request)
            .eq("id", value: id)
            .execute()
    }
    
    // MARK: - List Items
    
    func fetchListItems(listId: String) async throws -> [MediaListItem] {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        struct SupabaseListItem: Codable {
            let id: String
            let media_id: Int
            let media_type: String
            let title: String
            let poster_path: String?
            let added_at: Date
            let runtime: Int?
            let vote_average: Double?
            let vote_count: Int?
            let origin_country: [String]?
            let release_date: String?
            let genres: [Int]?
            let overview: String?
        }

        let region = Locale.current.region?.identifier ?? "US"
        do {
            let rows: [ListItemWithProvidersResponse] = try await client
                .rpc(
                    "get_list_items_with_providers",
                    params: ListItemsWithProvidersParams(p_list_id: listId, p_country: region)
                )
                .execute()
                .value

            for row in rows {
                guard let providers = row.countryProviders, providers.hasUsableProviders else { continue }
                await LocalWatchProvidersRepository.shared.save(
                    providers,
                    mediaId: row.item.media_id,
                    mediaType: MediaType(rawValue: row.item.media_type) ?? .movie,
                    region: region
                )
            }

            return rows.map { row in
                MediaListItem(
                    id: row.item.id,
                    mediaId: row.item.media_id,
                    mediaType: MediaType(rawValue: row.item.media_type) ?? .movie,
                    title: row.item.title,
                    posterPath: row.item.poster_path,
                    addedAt: row.item.added_at,
                    runtime: row.item.runtime,
                    voteAverage: row.item.vote_average,
                    voteCount: row.item.vote_count,
                    originCountry: row.item.origin_country,
                    releaseDate: row.item.release_date,
                    genres: row.item.genres,
                    overview: row.item.overview
                )
            }
        } catch {
            Logger.warning("[Supabase] get_list_items_with_providers failed, falling back to list_items fetch: \(error.localizedDescription)")
        }
        
        let items: [SupabaseListItem] = try await client
            .from("list_items")
            .select()
            .eq("list_id", value: listId)
            .is("deleted_at", value: nil)
            .order("added_at", ascending: false)
            .execute()
            .value
        
        return items.map { item in
            MediaListItem(
                id: item.id,
                mediaId: item.media_id,
                mediaType: MediaType(rawValue: item.media_type) ?? .movie,
                title: item.title,
                posterPath: item.poster_path,
                addedAt: item.added_at,
                runtime: item.runtime,
                voteAverage: item.vote_average,
                voteCount: item.vote_count,
                originCountry: item.origin_country,
                releaseDate: item.release_date,
                genres: item.genres,
                overview: item.overview
            )
        }
    }
    
    func addItemToList(listId: String, item: MediaListItem) async throws -> MediaListItem {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        guard let userId = currentUser?.id else {
            throw SupabaseError.notAuthenticated
        }
        
        struct AddItemRequest: Encodable {
            let id: String
            let list_id: String
            let user_id: String
            let media_id: Int
            let media_type: String
            let title: String
            let poster_path: String?
            let runtime: Int?
            let vote_average: Double?
            let vote_count: Int?
            let origin_country: [String]?
            let release_date: String?
            let genres: [Int]?
            let overview: String?
            let deleted_at: String?
        }

        let request = AddItemRequest(
            // Use the local item's id so the remote row, local SQLite row, and in-memory
            // item all share one id. Without this the server generates its own id, which
            // diverges from the id used by removeItemFromList/sync — leaving orphan remote
            // rows that reappear (e.g. a "mark as seen" reverting to the watchlist on relaunch).
            id: item.id,
            list_id: listId,
            user_id: userId,
            media_id: item.mediaId,
            media_type: item.mediaType.rawValue,
            title: item.title,
            poster_path: item.posterPath,
            runtime: item.runtime,
            vote_average: item.voteAverage,
            vote_count: item.voteCount,
            origin_country: item.originCountry,
            release_date: item.releaseDate,
            genres: item.genres,
            overview: item.overview,
            deleted_at: nil
        )
        
        struct AddItemResponse: Decodable {
            let id: String
            let added_at: Date
        }
        
        let response: AddItemResponse = try await client
            .from("list_items")
            .insert(request)
            .select("id, added_at")
            .single()
            .execute()
            .value
        
        return MediaListItem(
            id: response.id,
            mediaId: item.mediaId,
            mediaType: item.mediaType,
            title: item.title,
            posterPath: item.posterPath,
            addedAt: response.added_at,
            runtime: item.runtime,
            voteAverage: item.voteAverage,
            voteCount: item.voteCount,
            originCountry: item.originCountry,
            releaseDate: item.releaseDate,
            genres: item.genres,
            overview: item.overview
        )
    }
    
    func removeItemFromList(itemId: String) async throws {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }
        
        try await client
            .from("list_items")
            .delete()
            .eq("id", value: itemId)
            .execute()
    }
    
    // MARK: - Sync
    
    func syncLocalToCloud(lists: [MediaList]) async throws {
        // Upload all local lists and items to cloud
        for list in lists {
            // Create the list with the same local ID
            let cloudList = try await createList(
                id: list.id,  // Use same ID as local
                name: list.name,
                description: list.description,
                type: list.type
            )
            
            // Add all items
            for item in list.items {
                _ = try await addItemToList(listId: cloudList.id, item: item)
            }
        }
    }
    // MARK: - AI Request Usage
    //
    // Writes to the remote counter go through cerebras-proxy (the server that gates the daily AI
    // request limit), which is the single writer. The client only reads via getAITokenUsage and
    // keeps a local mirror; there is deliberately no client-side writer, so nothing here can
    // desynchronize the server's request count. (A dead logAITokenUsage that added token counts to
    // this request counter used to live here; it was removed.)
    func getAITokenUsage(userId: UUID) async throws -> Int {
        guard let client = client else {
            throw SupabaseError.notConfigured
        }

        let normalizedUserId = userId.uuidString.lowercased()
        let state = await normalizeLocalAITokenUsageForToday(userId: normalizedUserId)
        if state?.didResetForNewDay == true {
            await resetRemoteAITokenUsageIfPossible(userId: normalizedUserId)
        }
        
        struct GetUsageRequest: Encodable {
            let p_user_id: UUID
        }
        
        let request = GetUsageRequest(p_user_id: userId)
        
        do {
            let totalTokens: Int = try await client.rpc("get_ai_token_usage", params: request).execute().value

            // Cache locally for offline state (normalize casing)
            await saveLocalAITokenUsage(userId: normalizedUserId, tokensUsed: totalTokens)
            return totalTokens
        } catch {
            Logger.warning("[Supabase] get_ai_token_usage RPC failed; using local cache. Error: \(error.localizedDescription)")
            return await getLocalAITokenUsage(userId: normalizedUserId) ?? 0
        }
    }
    
    /// Cache AI token usage locally so the UI can reflect changes immediately/offline.
    func saveLocalAITokenUsage(userId: String, tokensUsed: Int) async {
        let normalizedUserId = normalizeUserId(userId)
        let now = ISO8601DateFormatter().string(from: Date())
        let todayKey = localDayKey()
        let row: [String: Any] = [
            "user_id": normalizedUserId,
            "tokens_used_today": tokensUsed,
            "usage_day": todayKey,
            "updated_at": now
        ]
        do {
            try await localDB.upsert(table: "user_ai_token_usage", rows: [row])
            Logger.debug("[SQLite] Cached AI tokens: \(tokensUsed) for user \(normalizedUserId)")
        } catch {
            Logger.warning("[SQLite] Failed to cache AI token usage locally: \(error.localizedDescription)")
        }
    }
    
    /// Read cached AI token usage from local SQLite (if available).
    func getLocalAITokenUsage(userId: String) async -> Int? {
        await normalizeLocalAITokenUsageForToday(userId: userId)?.tokens
    }

    // MARK: - User Profile
    //
    // P5 (SPEC v3): `updateUserProfile(_:)` and `fetchUserProfile()` lived here and existed only
    // to serve AppState.checkOnboardingFromProfile(). The update encoded a fixed payload of
    // `onboarding_completed` / `onboarding_completed_at`, two columns `profiles` does not have,
    // so every call was a guaranteed round-trip to a 42703. Both callers are gone; profile reads
    // for auth go through AuthService.fetchUserProfile(userId:), which reads columns that exist.

}

// MARK: - Public Lists (Fase 1)

extension SupabaseService {
    /// Feed liste pubbliche via RPC `get_public_lists` (ricerca parziale + scope explore/followed).
    /// La RPC applica già block (nei due versi), auto-hide oltre soglia report e l'esclusione
    /// delle non-pubbliche. Con `ownerId` restituisce le liste pubbliche di QUEL profilo (§9.3):
    /// stessa funzione, stesse difese, il feed resta il caso `nil`.
    func fetchPublicLists(search: String?, scope: PublicListsScope, limit: Int, offset: Int,
                          ownerId: String? = nil) async throws -> [PublicList] {
        guard let client = client else { throw SupabaseError.notConfigured }
        let trimmed = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows: [PublicListRow] = try await client
            .rpc("get_public_lists", params: PublicListsParams(
                p_search: (trimmed?.isEmpty == false) ? trimmed : nil,
                p_scope: scope.rawValue,
                p_limit: limit,
                p_offset: offset,
                p_owner: ownerId
            ))
            .execute()
            .value

        return rows.map { row in
            PublicList(
                id: row.id,
                name: row.name,
                description: row.description,
                type: ListType(rawValue: row.type) ?? .custom,
                itemCount: row.item_count,
                coverPosterPaths: row.cover_poster_paths ?? [],
                followerCount: row.follower_count,
                updatedAt: row.updated_at,
                isFollowing: row.is_following,
                ownerId: row.owner_id,
                ownerUsername: row.owner_username,
                ownerDisplayName: row.owner_display_name,
                ownerAvatarUrl: row.owner_avatar_url
            )
        }
    }

    /// Blocca l'autore di una lista pubblica (owner risolto lato server: nessun user_id esposto).
    func blockListOwner(listId: String) async throws {
        _ = try await callRPC(function: "block_list_owner", payload: ["p_list_id": listId])
    }
}

// MARK: - Activity Feed (Social feed M1)

extension SupabaseService {
    /// Il feed attività via RPC `get_activity_feed`. La RPC applica già privacy (opt-out),
    /// blocchi nei due versi e lo scope; la paginazione è keyset su (occurred_at, activity_id):
    /// `before` è la coda dell'ultima pagina, mai un offset — le card nuove in testa non fanno
    /// scivolare le pagine successive.
    func fetchActivityFeed(scope: ActivityFeedScope, userId: UUID?,
                           before: (Date, UUID)?, limit: Int) async throws -> [ActivityItem] {
        guard let client = client else { throw SupabaseError.notConfigured }
        // Il cursore viaggia come stringa ISO8601 con i frazionali: l'encoder di default
        // troncherebbe ai secondi e il confronto `occurred_at < p_before` salterebbe righe.
        let cursorFormatter = ISO8601DateFormatter()
        cursorFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows: [ActivityItem] = try await client
            .rpc("get_activity_feed", params: ActivityFeedParams(
                p_scope: scope.rawValue,
                p_user: userId?.uuidString.lowercased(),
                p_before: before.map { cursorFormatter.string(from: $0.0) },
                p_before_id: before.map { $0.1.uuidString.lowercased() },
                p_limit: limit
            ))
            .execute()
            .value
        return rows
    }

    /// Opt-out (e rientro) dal feed: `set_activity_feed_visibility` scrive il flag sul profilo
    /// lato server — nessuna colonna da conoscere qui, nessuna RLS da rilassare.
    func setActivityFeedVisibility(_ enabled: Bool) async throws {
        _ = try await callRPC(function: "set_activity_feed_visibility",
                              payload: ["p_enabled": enabled])
    }
}

// MARK: - Interazioni del feed (Social feed M2)

/// L'esito di un toggle come lo racconta il server: lo stato VERO dopo l'operazione.
/// È la fonte con cui il client riconcilia l'ottimismo — mai il contrario.
struct ActivityInteractionToggle: Decodable {
    let liked: Bool
    let likeCount: Int

    enum CodingKeys: String, CodingKey {
        case liked
        case likeCount = "like_count"
    }
}

/// Una riga di `get_activity_comments`: autore denormalizzato (il client non conosce i profili
/// altrui), lapidi con `content` nullo, contatori calcolati dal server.
struct ActivityCommentRow: Decodable {
    let commentId: UUID
    let userId: UUID
    let username: String?
    let displayName: String?
    let avatarUrl: String?
    let parentId: UUID?
    let content: String?
    let isDeleted: Bool
    let createdAt: Date
    let likeCount: Int
    let likedByMe: Bool

    enum CodingKeys: String, CodingKey {
        case commentId = "comment_id"
        case userId = "user_id"
        case username
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case parentId = "parent_id"
        case content
        case isDeleted = "is_deleted"
        case createdAt = "created_at"
        case likeCount = "like_count"
        case likedByMe = "liked_by_me"
    }
}

/// I due tipi che `report_content` accetta. Enum chiuso per costruzione: un content_type
/// sbagliato è un 500 evitabile a compile time.
enum ReportableContentType: String {
    case review
    case activityComment = "activity_comment"
}

extension SupabaseService {
    /// I toggle tornano da PostgREST come array di una riga (`returns table`). Un array vuoto
    /// è una risposta che non si capisce: errore, mai un default inventato.
    private func decodeToggle(_ rows: [ActivityInteractionToggle]) throws -> ActivityInteractionToggle {
        guard let row = rows.first else {
            throw SupabaseError.unexpectedResponse(body: "empty toggle response")
        }
        return row
    }

    /// Like/unlike su una card. `p_like_id` conta solo alla prima insert (idempotenza del
    /// re-like: il server rianima la stessa riga), quindi l'id va generato una volta per
    /// (attività, utente) e riusato — mai un UUID nuovo a ogni tap.
    func toggleActivityLike(activityId: UUID, likeId: UUID) async throws -> ActivityInteractionToggle {
        guard let client else { throw SupabaseError.notConfigured }
        struct Params: Encodable {
            let p_activity_id: String
            let p_like_id: String
        }
        let rows: [ActivityInteractionToggle] = try await client
            .rpc("toggle_activity_like", params: Params(
                p_activity_id: activityId.uuidString.lowercased(),
                p_like_id: likeId.uuidString.lowercased()))
            .execute()
            .value
        return try decodeToggle(rows)
    }

    /// Nuovo commento (o reply, un livello solo). L'id lo genera il CLIENT: un retry con lo
    /// stesso `p_comment_id` è un upsert, quindi il replay offline non duplica mai.
    func addActivityComment(activityId: UUID, content: String,
                            commentId: UUID, parentId: UUID?) async throws -> UUID {
        var payload: [String: Any] = [
            "p_activity_id": activityId.uuidString.lowercased(),
            "p_content": content,
            "p_comment_id": commentId.uuidString.lowercased()
        ]
        if let parentId { payload["p_parent_id"] = parentId.uuidString.lowercased() }

        let data = try await callRPC(function: "add_activity_comment", payload: payload)
        // `returns uuid` arriva come frammento JSON di primo livello ("una-stringa"):
        // stessa lezione di parseBooleanRPCResponse.
        guard let raw = (try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed])) as? String,
              let id = UUID(uuidString: raw) else {
            throw SupabaseError.unexpectedResponse(
                body: String(data: data.prefix(300), encoding: .utf8) ?? "<non-UTF8>")
        }
        return id
    }

    /// Cancella un commento: il server accetta il proprietario del commento O quello della
    /// card (moderazione di casa propria) — qui non si replica quella logica, la si invoca.
    func deleteActivityComment(commentId: UUID) async throws {
        _ = try await callRPC(function: "delete_activity_comment",
                              payload: ["p_comment_id": commentId.uuidString.lowercased()])
    }

    /// Like/unlike su un commento, stessa disciplina del like alla card.
    func toggleActivityCommentLike(commentId: UUID, likeId: UUID) async throws -> ActivityInteractionToggle {
        guard let client else { throw SupabaseError.notConfigured }
        struct Params: Encodable {
            let p_comment_id: String
            let p_like_id: String
        }
        let rows: [ActivityInteractionToggle] = try await client
            .rpc("toggle_activity_comment_like", params: Params(
                p_comment_id: commentId.uuidString.lowercased(),
                p_like_id: likeId.uuidString.lowercased()))
            .execute()
            .value
        return try decodeToggle(rows)
    }

    /// Il filo dei commenti: ordine cronologico ASCENDENTE con cursore in avanti
    /// (created_at, comment_id) — stessa disciplina keyset di `fetchActivityFeed`,
    /// frazionali inclusi per non saltare righe al confronto.
    func fetchActivityComments(activityId: UUID, after: (Date, UUID)?,
                               limit: Int) async throws -> [ActivityCommentRow] {
        guard let client else { throw SupabaseError.notConfigured }
        let cursorFormatter = ISO8601DateFormatter()
        cursorFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        struct Params: Encodable {
            let p_activity_id: String
            let p_limit: Int
            let p_after: String?
            let p_after_id: String?
        }
        let rows: [ActivityCommentRow] = try await client
            .rpc("get_activity_comments", params: Params(
                p_activity_id: activityId.uuidString.lowercased(),
                p_limit: limit,
                p_after: after.map { cursorFormatter.string(from: $0.0) },
                p_after_id: after.map { $0.1.uuidString.lowercased() }))
            .execute()
            .value
        return rows
    }

    /// Segnalazione contenuti. Idempotente sul server (ON CONFLICT DO NOTHING): ri-segnalare
    /// non è un errore, quindi qui non serve nessuno stato locale.
    func reportContent(type: ReportableContentType, id: UUID, reason: String? = nil) async throws {
        var payload: [String: Any] = [
            "p_content_type": type.rawValue,
            "p_content_id": id.uuidString.lowercased()
        ]
        if let reason, !reason.isEmpty { payload["p_reason"] = reason }
        _ = try await callRPC(function: "report_content", payload: payload)
    }
}

private struct ActivityFeedParams: Encodable {
    let p_scope: String
    let p_user: String?
    let p_before: String?
    let p_before_id: String?
    let p_limit: Int
}

private struct PublicListsParams: Encodable {
    let p_search: String?
    let p_scope: String
    let p_limit: Int
    let p_offset: Int
    let p_owner: String?
}

private struct PublicListRow: Decodable {
    let id: String
    let name: String
    let description: String?
    let type: String
    let updated_at: Date?
    let item_count: Int
    let cover_poster_paths: [String]?
    let follower_count: Int
    let is_following: Bool
    // Social feed M1: l'autore esce dall'anonimato. Optional non per pigrizia: un server non
    // ancora migrato non manda le colonne, e il feed liste deve continuare a decodificarsi.
    let owner_id: String?
    let owner_username: String?
    let owner_display_name: String?
    let owner_avatar_url: String?
}

private struct ListItemsWithProvidersParams: Encodable {
    let p_list_id: String
    let p_country: String
}

private struct ListItemWithProvidersResponse: Decodable {
    let item: RemoteListItem
    let providers: [RemoteAvailabilityProvider]

    var countryProviders: CountryProviders? {
        var result = CountryProviders(flatrate: [], rent: [], buy: [], link: nil)

        for remote in providers {
            guard let provider = remote.provider else { continue }
            let type = (remote.availability_type ?? remote.monetization_type ?? remote.type ?? "streaming").lowercased()

            if result.link == nil {
                result.link = remote.link ?? remote.external_link
            }

            if type.contains("rent") {
                result.rent?.append(provider)
            } else if type.contains("buy") || type.contains("purchase") {
                result.buy?.append(provider)
            } else {
                result.flatrate?.append(provider)
            }
        }

        if result.flatrate?.isEmpty == true { result.flatrate = nil }
        if result.rent?.isEmpty == true { result.rent = nil }
        if result.buy?.isEmpty == true { result.buy = nil }

        return result.hasUsableProviders ? result : nil
    }
}

private struct RemoteListItem: Decodable {
    let id: String
    let media_id: Int
    let media_type: String
    let title: String
    let poster_path: String?
    let added_at: Date
    let runtime: Int?
    let vote_average: Double?
    let vote_count: Int?
    let origin_country: [String]?
    let release_date: String?
    let genres: [Int]?
    let overview: String?
}

private struct RemoteAvailabilityProvider: Decodable {
    let provider_id: Int?
    let provider_name: String?
    let logo_path: String?
    let display_priority: Int?
    let availability_type: String?
    let monetization_type: String?
    let type: String?
    let link: String?
    let external_link: String?

    var provider: Provider? {
        guard let provider_id, let provider_name else { return nil }
        return Provider(
            providerId: provider_id,
            providerName: provider_name,
            logoPath: logo_path ?? "",
            displayPriority: display_priority ?? 0,
            price: nil,
            quality: nil,
            presentationType: availability_type ?? monetization_type,
            externalLink: (external_link ?? link).flatMap(URL.init(string:))
        )
    }
}

extension Notification.Name {
    static let aiTokenUsageDidReset = Notification.Name("aiTokenUsageDidReset")
}


enum SupabaseError: LocalizedError {
    case notConfigured
    case notAuthenticated
    /// La sessione GoTrue non è recuperabile (refresh rifiutato o assente): serve un
    /// nuovo sign-in. Distinto da `notAuthenticated` perché l'app CREDEVA di essere
    /// loggata — chi lo riceve deve dirlo all'utente, non trattarlo come un guasto.
    case sessionExpired
    case authenticationFailed
    case networkError
    case httpError(statusCode: Int, body: String)
    case unexpectedResponse(body: String)
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supabase is not configured. Please add your credentials to Config.swift"
        case .notAuthenticated:
            return "You must be signed in to perform this action"
        case .sessionExpired:
            return "Your session has expired. Please sign in again"
        case .authenticationFailed:
            return "Authentication failed. Please check your credentials"
        case .networkError:
            return "Network error. Please check your connection"
        case .httpError(let statusCode, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let short = trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
            return "Supabase HTTP \(statusCode): \(short.isEmpty ? "No response body" : short)"
        case .unexpectedResponse(let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let short = trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
            return "Unexpected Supabase response: \(short.isEmpty ? "empty body" : short)"
        }
    }
}
