import Foundation
import Combine

enum ListError: LocalizedError, Equatable {
    case maxListsReached(limit: Int)
    case maxItemsReached(limit: Int)
    case listNotFound
    case itemAlreadyInList
    case defaultListImmutable
    case invalidName
    case authenticationRequired
    
    var errorDescription: String? {
        switch self {
        case .maxListsReached(let limit):
            return "lists.error.maxListsReached".localizedMainSafe().replacingOccurrences(of: "{limit}", with: "\(limit)")
        case .maxItemsReached(let limit):
            return "lists.error.maxItemsReached".localizedMainSafe().replacingOccurrences(of: "{limit}", with: "\(limit)")
        case .listNotFound:
            return "lists.error.listNotFound".localizedMainSafe()
        case .itemAlreadyInList:
            return "lists.error.itemAlreadyInList".localizedMainSafe()
        case .defaultListImmutable:
            return "lists.error.defaultImmutable".localizedMainSafe()
        case .invalidName:
            return "lists.error.invalidName".localizedMainSafe()
        case .authenticationRequired:
            return "lists.error.authRequired".localizedMainSafe()
        }
    }
}

@MainActor
class ListManager: ObservableObject {
    static let shared = ListManager()
    
    // Limits
    static let proMaxCustomLists = 100
    static let freeMaxCustomLists = 2
    static let maxItemsPerList = 1000
    static let softLimitWarningThreshold = 500
    
    @Published var lists: [MediaList] = []
    @Published var watchlist: MediaList
    @Published var seenList: MediaList
    @Published var likedList: MediaList
    @Published var dislikedList: MediaList
    @Published var softLimitWarningMessage: String?
    @Published var isLoadingInitial = true
    
    private let db: SQLiteService
    private let sync: SyncEngineProtocol
    private let supabase: ListsRemoteDataSource
    private let authService: AuthStatusProviding
    /// Fusione ListsView-Tracking: le azioni TV su watchlist/seen passano da qui. Override per i
    /// test; in produzione il singleton, risolto pigramente (TrackingActions dipende da
    /// SyncEngine.shared, e crearlo dentro l'init del singleton ListManager è un ordine di
    /// inizializzazione che non va forzato).
    private let trackingActionsOverride: TrackingActions?
    private var trackingActions: TrackingActions { trackingActionsOverride ?? .shared }
    private var cancellables = Set<AnyCancellable>()
    private var userId: String {
        authService.currentUser?.id ?? DeviceIdentity.installation
    }

    var currentCustomListLimit: Int {
        EntitlementPolicy.maxCustomLists(for: DailyQuotaManager.shared.isProUser ? .pro : .free)
    }

    /// Designated initializer with injectable dependencies (test enabler).
    /// Production keeps using `.shared` with the singleton defaults; tests can pass a
    /// SQLiteService backed by a temp DB plus mocks, and set `autoStart: false` to avoid
    /// triggering the initial load and the auth/locale observers.
    init(
        db: SQLiteService = .shared,
        sync: SyncEngineProtocol = SyncEngine.shared,
        supabase: ListsRemoteDataSource = SupabaseService.shared,
        authService: AuthStatusProviding = AuthService.shared,
        trackingActions: TrackingActions? = nil,
        autoStart: Bool = true
    ) {
        self.db = db
        self.sync = sync
        self.supabase = supabase
        self.authService = authService
        self.trackingActionsOverride = trackingActions

        // Initialize default lists with stable type-keyed names
        self.watchlist = MediaList(name: ListType.watchlist.rawValue, type: .watchlist)
        self.seenList = MediaList(name: ListType.seen.rawValue, type: .seen)
        self.likedList = MediaList(name: ListType.liked.rawValue, type: .liked)
        self.dislikedList = MediaList(name: ListType.disliked.rawValue, type: .disliked)
        self.softLimitWarningMessage = nil

        guard autoStart else { return }

        loadLists()

        // Observe authentication state changes
        authService.isAuthenticatedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAuthenticated in
                guard let self = self else { return }
                Task {
                    if isAuthenticated {
                        await self.syncListsForAuthenticatedUser()
                    } else {
                        self.resetListsForLoggedOutUser()
                    }
                }
            }
            .store(in: &cancellables)

        // Re-publish when language changes so views re-render with updated displayName
        LocalizationManager.shared.$localeDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Fusione ListsView-Tracking: le sezioni TV di watchlist/seen derivano dallo specchio
        // `tv_tracking`, che solo un pull aggiorna — quindi a ogni sync completato le liste vanno
        // riderivate, o un import/un'azione tracking resterebbero invisibili qui fino al riavvio.
        NotificationCenter.default.publisher(for: .syncEngineCompleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.authService.currentUser != nil else { return }
                Task { await self.loadListsFromSQLite() }
            }
            .store(in: &cancellables)
    }
    
    // Call this when user logs in
    func syncListsForAuthenticatedUser() async {
        guard let authenticatedUserId = authService.currentUser?.id else {
            Logger.warning("[ListManager] Not authenticated, cannot sync remote lists.")
            return
        }

        Logger.info("[ListManager] Syncing lists for authenticated user: \(authenticatedUserId.prefix(8))...")

        // Garantisce la riga profiles(authenticatedUserId) PRIMA di scrivere lists/list_items
        // sotto quell'id: lists.user_id e list_items.user_id hanno FK → profiles(id). Se il
        // profilo manca (la riga viene creata da ensureDeviceProfileInSQLite all'avvio, spesso
        // ancora con il deviceId perché l'auth non è stata ripristinata), ogni insert locale
        // dell'utente autenticato fallirebbe in silenzio nel catch.
        await ensureDeviceProfileInSQLite()

        do {
            // 0. Flush any locally-queued changes (adds/removes/moves) to Supabase BEFORE
            //    pulling remote state. Otherwise a pull can clobber local edits that haven't
            //    synced yet — e.g. a "mark as seen" done just before relaunch would be
            //    overwritten by stale remote rows and appear to revert to the watchlist.
            await sync.pushPendingChanges()

            // 1. Fetch remote lists for the authenticated user
            var remoteLists = try await supabase.fetchLists()
            Logger.info("[ListManager] Fetched \(remoteLists.count) remote lists from Supabase.")
            
            // 2. Load current local lists (which might still contain anonymous lists)
            let localListsBeforeSync = lists
            
            // 3. Merge/Prioritize: Remote lists become the primary source.
            //    Ensure core lists are present in remote lists
            remoteLists = ensureCoreLists(in: remoteLists)
            
            // 4. Handle custom local lists that might not be on Supabase yet
            //    These are lists created by the user when they were anonymous on this device.
            //    Single remote writer (4.3): l'upload va via outbox/SyncEngine, NON più con
            //    N chiamate dirette supabase.createList + supabase.addItemToList (burst N+1 al
            //    login). Accodiamo lista + item sull'outbox (persistendoli anche localmente) e
            //    li flushiamo in coda con UNA singola apply_mutations batch.
            var didEnqueueLocalUploads = false
            for localList in localListsBeforeSync where localList.type == .custom {
                guard !remoteLists.contains(where: { $0.id == localList.id }) else { continue }

                await ensureListInSQLite(localList)
                let now = ISO8601DateFormatter().string(from: Date())
                try await sync.queueOperation(
                    table: "lists",
                    operationType: "INSERT",
                    recordId: localList.id,
                    payload: [
                        "id": localList.id,
                        "user_id": authenticatedUserId,
                        "name": localList.name,
                        "description": localList.description ?? "",
                        "type": ListType.custom.rawValue,
                        "created_at": ISO8601DateFormatter().string(from: localList.createdAt),
                        "updated_at": now
                    ],
                    dependsOn: nil
                )

                // addItemToSQLite persiste in SQLite E accoda INSERT list_items sull'outbox.
                for item in localList.items {
                    await addItemToSQLite(item, listId: localList.id)
                }

                remoteLists.append(localList) // Add to our working set of lists
                didEnqueueLocalUploads = true
                Logger.info("[ListManager] Queued local custom list '\(localList.name)' (\(localList.items.count) items) for remote sync.")
            }

            // 5. Update local state with the merged lists
            applyLists(remoteLists)
            // Il pull può aver portato in memoria liste core con un id REMOTO diverso dalla
            // canonica locale. Con l'indice univoco parziale su lists(user_id, type) quell'id
            // remoto non può essere persistito (INSERT OR IGNORE lo salta) → un add successivo
            // fallirebbe la FK e l'item sparirebbe. Riallinea le core all'id canonico locale
            // PRIMA di salvare, così saveListsToSQLite scrive su righe realmente esistenti.
            await reconcileCoreListIdentities()
            await saveListsToSQLite()

            // 6. Flush subito le liste locali-only appena accodate, così restano "caricate al
            //    login" come prima — ma in UNA apply_mutations batch invece del vecchio N+1.
            if didEnqueueLocalUploads {
                await sync.pushPendingChanges()
            }

            Logger.info("[ListManager] Lists synced successfully for authenticated user.")

        } catch {
            Logger.error("[ListManager] Error syncing lists for authenticated user: \(error)")
            // If fetching remote lists fails, perhaps revert to local only or show error
            // For now, we'll just log and keep whatever local state was there
        }

        // Ricarica SEMPRE lo stato LOCALE per l'utente autenticato (offline-first), anche se il
        // pull remoto sopra è fallito. Decisivo per il bug "gli item spariscono al riavvio": al
        // cold launch loadListsFromSQLite gira con il deviceId (la sessione auth non è ancora
        // ripristinata) e carica le liste del DEVICE, vuote; i passi 1-5 ricostruiscono lo stato
        // in memoria dal REMOTO (fetchLists), che però può non contenere gli item non ancora
        // sincronizzati (es. push outbox fallito) → gli item già in SQLite sotto l'id autenticato
        // non venivano MAI caricati in memoria. Ora `currentUser` è valorizzato: questa load legge
        // le liste+item locali dell'utente autenticato e li rende visibili (il remoto è già stato
        // fuso in SQLite da saveListsToSQLite, INSERT OR IGNORE non distruttivo).
        await loadListsFromSQLite()
    }
    
    // Call this when user logs out
    func resetListsForLoggedOutUser() {
        Logger.info("[ListManager] Resetting lists for logged out user.")
        
        // Clear all lists and revert to empty default lists only
        // This ensures no authenticated user data remains visible
        let emptyWatchlist = MediaList(name: ListType.watchlist.rawValue, type: .watchlist)
        let emptySeenList = MediaList(name: ListType.seen.rawValue, type: .seen)
        let emptyLikedList = MediaList(name: ListType.liked.rawValue, type: .liked)
        let emptyDislikedList = MediaList(name: ListType.disliked.rawValue, type: .disliked)
        
        // Set lists to only empty default lists
        self.lists = [emptyWatchlist, emptySeenList, emptyLikedList, emptyDislikedList]
        self.watchlist = emptyWatchlist
        self.seenList = emptySeenList
        self.likedList = emptyLikedList
        self.dislikedList = emptyDislikedList
        
        // Save the empty state to SQLite
        Task { await saveListsToSQLite() }

        Logger.info("[ListManager] Lists cleared for logged out user - showing empty defaults only.")
    }
    
    func loadLists() {
        // Load from SQLite ONLY (single source of truth)
        Task {
            await migrateFromUserDefaultsIfNeeded()
            await loadListsFromSQLite()
            isLoadingInitial = false
            await ensureListsInDatabase()
        }
    }

    /// One-time migration: import lists from UserDefaults to SQLite, then delete the key
    private func migrateFromUserDefaultsIfNeeded() async {
        let userDefaultsKey = "media_lists"
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([MediaList].self, from: data) else {
            return
        }

        Logger.info("[ListManager] Migrating \(decoded.count) lists from UserDefaults to SQLite...")
        for list in decoded {
            await ensureListInSQLite(list)
            for item in list.items {
                await addItemToSQLite(item, listId: list.id)
            }
        }

        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        Logger.info("[ListManager] Migration complete. Removed UserDefaults key '\(userDefaultsKey)'")
    }

    /// Load lists from SQLite (single source of truth)
    /// Internal (not private) so the full-set load invariant can be characterized in tests.
    func loadListsFromSQLite() async {
        let currentUserId = authService.currentUser?.id ?? DeviceIdentity.installation

        do {
            let listsQuery = """
                SELECT l.id, l.name, l.description, l.type, l.created_at, l.is_public
                FROM lists l
                WHERE l.user_id = ? AND l.deleted_at IS NULL
                ORDER BY l.created_at DESC
            """
            let listRows = try await db.queryRaw(listsQuery, parameters: [currentUserId])

            guard !listRows.isEmpty else {
                // No lists in SQLite - initialize with defaults (fusi col tracking: un utente
                // possono non avere liste legacy ma avere serie nel tracking, es. post-import).
                self.lists = await fuseTrackingItems(
                    into: [watchlist, seenList, likedList, dislikedList], userId: currentUserId)
                updateDefaultReferences(from: self.lists)
                Logger.info("[ListManager] No lists in SQLite. Initialized defaults.")
                return
            }

            let listIds = listRows.compactMap { $0["id"] as? String }
            let placeholders = listIds.map { _ in "?" }.joined(separator: ", ")
            // Colonne esplicite, non `SELECT *`: `queryRaw` costruisce un dizionario per ogni riga,
            // quindi ogni colonna in più è memoria e lavoro per l'intero set. `user_id`,
            // `updated_at`, `deleted_at` e `synced_at` non sono lette né qui né da
            // `MediaListItem.from(dictionary:)`. Misurato: ~15% in meno su 4.000 righe.
            //
            // NB: niente `LIMIT`. Il set completo è un'invariante verificata da
            // `test_loadFromSQLite_loadsFullItemSet_countAndMembership`: `isInList` e
            // `canAddToList` interrogano quanto è in RAM, e troncare qui ha già causato in passato
            // il bug "al secondo avvio la lista mostra 1 elemento invece di 141".
            let itemsQuery = """
                SELECT id, list_id, media_id, media_type, title, poster_path, runtime,
                       vote_average, vote_count, origin_country, release_date, genres,
                       overview, added_at
                FROM list_items
                WHERE list_id IN (\(placeholders)) AND deleted_at IS NULL
                ORDER BY added_at DESC
            """
            let itemRows = try await db.queryRaw(itemsQuery, parameters: listIds)

            var itemsByListId: [String: [MediaListItem]] = [:]
            for row in itemRows {
                guard let listId = row["list_id"] as? String,
                      let item = MediaListItem.from(dictionary: row) else { continue }
                itemsByListId[listId, default: []].append(item)
            }

            var loadedLists: [MediaList] = []
            for row in listRows {
                guard let id = row["id"] as? String,
                      let name = row["name"] as? String,
                      let typeRaw = row["type"] as? String,
                      let type = ListType(rawValue: typeRaw) else { continue }

                let items = itemsByListId[id] ?? []
                let list = MediaList(
                    id: id,
                    name: name,
                    description: row["description"] as? String,
                    type: type,
                    createdAt: ISO8601DateFormatter().date(from: row["created_at"] as? String ?? "") ?? Date(),
                    items: items,
                    isPublic: (row["is_public"] as? Int ?? 0) != 0
                )
                loadedLists.append(list)
            }

            let fusedLists = await fuseTrackingItems(into: loadedLists, userId: currentUserId)
            applyLists(fusedLists)
            await reconcileCoreListIdentities()
            Logger.info("[ListManager] Loaded \(loadedLists.count) lists with \(itemRows.count) items from SQLite")
        } catch {
            Logger.error("[ListManager] Failed to load from SQLite: \(error)")
            // Initialize with defaults rather than failing silently
            self.lists = [watchlist, seenList, likedList, dislikedList]
        }
    }
    
    // MARK: - Fusione ListsView-Tracking (2026-08-02, decisione di prodotto)

    /// Il prefisso degli id sintetici degli item derivati dal tracking. Non esistono in
    /// `list_items`: qualunque strada di scrittura legacy che li incontrasse deve poterli
    /// riconoscere invece di fare un UPDATE su una riga che non c'è.
    static let trackingItemPrefix = "tracking:"

    /// Le sezioni TV di watchlist e seen non si leggono più da `list_items`: si DERIVANO dallo
    /// specchio `tv_tracking` — la stessa fonte della tab Tracking, zero rete (§13.6). I film
    /// restano su `list_items`, che continua a possedere anche liked/disliked/custom.
    ///
    /// Le regole, decise dall'utente il 2026-08-02:
    ///   - watchlist TV = bucket `not_started` ("Da iniziare") ∪ `for_later`;
    ///   - seen TV      = bucket `up_to_date` (hai visto tutto ciò che è uscito);
    ///   - le archiviate e le droppate NON compaiono (vivono solo nel Tracking);
    ///   - le serie a metà sono "in corso": stanno nel Tracking, non sono ancora "viste".
    ///
    /// Solo per utenti autenticati: il tracking è server-authoritative e per un anonimo lo
    /// specchio è vuoto — filtrare le sue righe TV legacy significherebbe nascondergli dati.
    private func fuseTrackingItems(into lists: [MediaList], userId: String) async -> [MediaList] {
        guard authService.currentUser != nil else { return lists }

        let derived = await trackingDerivedItems(userId: userId)

        var seenTypes = Set<ListType>()
        var result = lists.map { list -> MediaList in
            guard list.type == .watchlist || list.type == .seen else { return list }
            var fused = list
            // Le righe TV legacy si filtrano via da TUTTE le watchlist/seen (dopo la migrazione
            // 6 la core è una, ma un duplicato non deve far ricomparire dati vecchi due volte);
            // gli item derivati entrano solo nella prima, quella canonica.
            let movieItems = list.items.filter { $0.mediaType != .tv }
            let isFirstOfType = seenTypes.insert(list.type).inserted
            let trackingItems = isFirstOfType
                ? (list.type == .watchlist ? derived.watchlist : derived.seen)
                : []
            fused.items = (movieItems + trackingItems).sorted { $0.addedAt > $1.addedAt }
            return fused
        }

        // Un utente può non avere MAI avuto una di queste liste in SQLite (es. importato da TV
        // Time senza aver mai salvato niente): il tracking ha materiale ma la lista non esiste —
        // si crea dal default, o le serie derivate non avrebbero dove comparire.
        if !derived.watchlist.isEmpty, !seenTypes.contains(.watchlist) {
            var l = watchlist
            l.items = derived.watchlist.sorted { $0.addedAt > $1.addedAt }
            result.append(l)
        }
        if !derived.seen.isEmpty, !seenTypes.contains(.seen) {
            var l = seenList
            l.items = derived.seen.sorted { $0.addedAt > $1.addedAt }
            result.append(l)
        }

        return result
    }

    /// Gli item sintetizzati dallo specchio `tv_tracking`, con lo stesso JOIN sui titoli
    /// localizzati del repository del Tracking (il nome del catalogo parla una lingua sola, §1.5).
    private func trackingDerivedItems(
        userId: String
    ) async -> (watchlist: [MediaListItem], seen: [MediaListItem]) {
        let sql = """
            SELECT t.tmdb_show_id, t.bucket,
                   COALESCE(lt.title, t.show_name) AS title,
                   t.show_poster_path, t.updated_at, t.completed_at, t.last_watched_at
              FROM tv_tracking t
              LEFT JOIN localized_titles lt
                ON lt.media_type = 'tv' AND lt.tmdb_id = t.tmdb_show_id AND lt.language = ?
             WHERE t.user_id = ? AND t.bucket IN ('not_started', 'for_later', 'up_to_date')
        """

        do {
            let language = LocalizationManager.shared.currentLanguage.id
            let rows = try await db.queryRaw(sql, parameters: [language, userId])

            var watchlistItems: [MediaListItem] = []
            var seenItems: [MediaListItem] = []

            for row in rows {
                guard let showId = row["tmdb_show_id"] as? Int,
                      let bucket = row["bucket"] as? String else { continue }
                // Senza nome non c'è niente da mostrare: capita solo se il catalogo non ha
                // ancora la serie, e in quel caso è la card del Tracking il posto dove appare.
                guard let title = row["title"] as? String, !title.isEmpty else { continue }

                let addedAt: Date
                if bucket == "up_to_date" {
                    // Per una "vista" la data sensata è quando l'hai finita, con ripieghi onesti.
                    addedAt = Self.parseTrackingDate(row["completed_at"] as? String)
                        ?? Self.parseTrackingDate(row["last_watched_at"] as? String)
                        ?? Self.parseTrackingDate(row["updated_at"] as? String)
                        ?? Date()
                } else {
                    addedAt = Self.parseTrackingDate(row["updated_at"] as? String) ?? Date()
                }

                let item = MediaListItem(
                    id: Self.trackingItemPrefix + String(showId),
                    mediaId: showId,
                    mediaType: .tv,
                    title: title,
                    posterPath: row["show_poster_path"] as? String,
                    addedAt: addedAt
                )

                if bucket == "up_to_date" { seenItems.append(item) } else { watchlistItems.append(item) }
            }

            return (watchlistItems, seenItems)
        } catch {
            // Un errore qui non deve buttare giù le liste dei film: si logga e le sezioni TV
            // restano vuote per questo giro — il prossimo sync le rideriva.
            Logger.error("[ListManager] Derivazione dal tracking fallita: \(error)")
            return ([], [])
        }
    }

    /// Le date dello specchio arrivano dal server in ISO8601, con o senza frazioni di secondo:
    /// `ISO8601DateFormatter` di default rifiuta le frazioni, e il fallback muto su `Date()`
    /// metterebbe ogni serie "aggiunta adesso".
    private static let isoWithFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parseTrackingDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return isoWithFractions.date(from: value) ?? isoPlain.date(from: value)
    }

    /// Riallinea ogni lista core in memoria (watchlist/seen/liked/disliked) all'id CANONICO
    /// presente in SQLite, così le scritture (addItemToSQLite) puntano sempre a una riga che
    /// esiste davvero.
    ///
    /// Dopo la migrazione 6 esiste UNA sola lista core attiva per (user, type) — la più vecchia
    /// con item. Ma il pull remoto (`fetchLists` → `applyLists`) può mettere in memoria una core
    /// con id remoto diverso; l'indice univoco parziale impedisce di persistere quell'id, quindi
    /// un item aggiunto contro di esso colpirebbe la FK e sparirebbe. Qui adottiamo l'id canonico
    /// e fondiamo gli item per (mediaId, mediaType) così nulla scompare visivamente.
    func reconcileCoreListIdentities() async {
        let coreTypes: [ListType] = [.watchlist, .seen, .liked, .disliked]
        for type in coreTypes {
            guard let memIndex = lists.firstIndex(where: { $0.type == type }) else { continue }
            let current = lists[memIndex]

            let rows = (try? await db.queryRaw(
                "SELECT id, created_at FROM lists WHERE user_id = ? AND type = ? AND deleted_at IS NULL ORDER BY created_at ASC, id ASC LIMIT 1",
                parameters: [userId, type.rawValue]
            )) ?? []

            guard let canonId = rows.first?["id"] as? String else {
                // Nessuna riga canonica: persisti quella in memoria così diventa la canonica.
                await ensureListInSQLite(current)
                continue
            }

            guard canonId != current.id else { continue }

            var seenKeys = Set<String>()
            let mergedItems = current.items.filter {
                seenKeys.insert("\($0.mediaId)-\($0.mediaType.rawValue)").inserted
            }
            let createdAt = ISO8601DateFormatter().date(from: rows.first?["created_at"] as? String ?? "") ?? current.createdAt
            lists[memIndex] = MediaList(
                id: canonId,
                name: current.name,
                description: current.description,
                type: type,
                createdAt: createdAt,
                items: mergedItems
            )
        }
        updateDefaultReferences(from: lists)
    }

    /// Ensure all in-memory lists exist in both SQLite and Supabase.
    ///
    /// 4.3b — taglio dell'N+1 a ogni avvio: prima questo metodo faceva `supabase.createList`
    /// DIRETTO per OGNI lista a ogni cold launch (4+ round-trip per lo più falliti per conflitto
    /// PK). Ora:
    ///  - lo facciamo SOLO per le liste non ancora riconciliate col remoto (`synced_at IS NULL`):
    ///    per gli utenti esistenti (liste già pull-ate) il costo remoto al lancio è ZERO.
    ///  - liste di DEFAULT (non cancellabili) → via outbox/SyncEngine (single remote writer 4.2);
    ///    `apply_mutations` fa un upsert idempotente e, non potendo essere soft-deleted, non c'è
    ///    rischio di "resurrection".
    ///  - liste CUSTOM → restano sul `createList` DIRETTO insert-or-fail. È deliberato: le custom
    ///    SONO cancellabili e `apply_mutations` su `lists` è un upsert → un INSERT via outbox
    ///    potrebbe riportare in vita una custom soft-deleted su un altro device (famiglia 141→1).
    ///    L'insert-or-fail (fallisce su riga esistente) preserva la non-resurrection.
    func ensureListsInDatabase() async {
        // First, ensure device profile exists in SQLite (for foreign key constraint)
        await ensureDeviceProfileInSQLite()

        for list in lists {
            // Ensure in SQLite
            await ensureListInSQLite(list)
        }

        guard authService.currentUser != nil else { return }

        for list in lists {
            // Salta le liste già riconciliate col remoto: niente più burst a ogni avvio.
            guard await listNeedsRemoteEnsure(list.id) else { continue }

            if list.type == .custom {
                // Custom: createList diretto insert-or-fail (no resurrection, vedi doc sopra).
                do {
                    _ = try await supabase.createList(id: list.id, name: list.name, description: list.description, type: list.type)
                    Logger.debug("[ListManager] Ensured custom list '\(list.name)' exists in Supabase")
                } catch {
                    // List might already exist, which is fine
                    Logger.debug("[ListManager] Custom list '\(list.name)' may already exist in Supabase: \(error)")
                }
            } else {
                // Default: via outbox (single remote writer).
                let now = ISO8601DateFormatter().string(from: Date())
                try? await sync.queueOperation(
                    table: "lists",
                    operationType: "INSERT",
                    recordId: list.id,
                    payload: [
                        "id": list.id,
                        "user_id": userId,
                        "name": list.name,
                        "description": list.description ?? "",
                        "type": list.type.rawValue,
                        "created_at": ISO8601DateFormatter().string(from: list.createdAt),
                        "updated_at": now
                    ],
                    dependsOn: nil
                )
                Logger.debug("[ListManager] Queued default list '\(list.name)' for remote ensure")
            }
        }
    }

    /// True se la lista locale non risulta ancora riconciliata col remoto (`synced_at IS NULL`),
    /// quindi va garantita lato server. Il pull remoto popola `synced_at` (vedi SQLiteService.upsert).
    private func listNeedsRemoteEnsure(_ id: String) async -> Bool {
        let rows = (try? await db.queryRaw(
            "SELECT synced_at FROM lists WHERE id = ?",
            parameters: [id]
        )) ?? []
        guard let row = rows.first else { return true }
        return (row["synced_at"] as? String) == nil
    }
    
    /// Ensure device profile exists in SQLite (required for foreign key constraint)
    private func ensureDeviceProfileInSQLite() async {
        // `profiles.email` ha un vincolo UNIQUE. Usare una email fissa ("device@local") per
        // OGNI profilo significa che, dopo il login, l'INSERT OR IGNORE del profilo dell'utente
        // autenticato collide sull'email del profilo-device già esistente e viene SALTATO in
        // silenzio → la riga profiles(authedUserId) non nasce mai → ogni scrittura su
        // lists/list_items con quel user_id viola la FK (foreign_keys=ON) e l'item "sparisce".
        // Email univoca per user_id → ogni profilo (device o autenticato) viene creato.
        let placeholderEmail = "\(userId)@local"
        let success = db.execute("""
            INSERT OR IGNORE INTO profiles (id, email, display_name, avatar_url, created_at, updated_at)
            VALUES (?, ?, ?, ?, datetime('now'), datetime('now'))
        """, parameters: [
            userId,
            placeholderEmail,
            "Local User",
            nil as String? as Any
        ])

        if success {
            Logger.debug("[ListManager] Ensured profile \(userId.prefix(8)) exists in SQLite")
        } else {
            Logger.warning("[ListManager] Failed to ensure profile in SQLite")
        }
    }
    
    private func ensureListInSQLite(_ list: MediaList) async {
        await ensureDeviceProfileInSQLite()
        let success = db.execute("""
            INSERT OR IGNORE INTO lists (id, name, description, type, created_at, user_id)
            VALUES (?, ?, ?, ?, ?, ?)
        """, parameters: [
            list.id,
            list.name,
            list.description ?? "",
            list.type.rawValue,
            ISO8601DateFormatter().string(from: list.createdAt),
            userId
        ])
        
        if success {
            Logger.debug("[ListManager] Ensured list '\(list.name)' exists in SQLite")
        } else {
            Logger.warning("[ListManager] Failed to ensure list '\(list.name)' in SQLite")
        }
    }

    private func applyLists(_ source: [MediaList]) {
        let merged = ensureCoreLists(in: source)
        self.lists = merged
        updateDefaultReferences(from: merged)
    }
    
    private func ensureCoreLists(in source: [MediaList]) -> [MediaList] {
        var finalLists = source
        for type in [ListType.watchlist, .seen, .liked, .disliked] {
            if !finalLists.contains(where: { $0.type == type }) {
                finalLists.insert(defaultList(for: type), at: 0)
            }
        }
        return finalLists
    }
    
    private func updateDefaultReferences(from lists: [MediaList]) {
        if let watchlist = lists.first(where: { $0.type == .watchlist }) {
            self.watchlist = watchlist
        }
        if let seen = lists.first(where: { $0.type == .seen }) {
            self.seenList = seen
        }
        if let liked = lists.first(where: { $0.type == .liked }) {
            self.likedList = liked
        }
        if let disliked = lists.first(where: { $0.type == .disliked }) {
            self.dislikedList = disliked
        }
    }
    
    private func defaultList(for type: ListType) -> MediaList {
        switch type {
        case .watchlist: return MediaList(name: ListType.watchlist.rawValue, type: .watchlist)
        case .seen: return MediaList(name: ListType.seen.rawValue, type: .seen)
        case .liked: return MediaList(name: ListType.liked.rawValue, type: .liked)
        case .disliked: return MediaList(name: ListType.disliked.rawValue, type: .disliked)
        case .custom: return MediaList(name: "custom", type: .custom)
        }
    }
    
    /// Save all current lists (metadata + items) to SQLite
    private func saveListsToSQLite() async {
        for list in lists {
            await ensureListInSQLite(list)
            if !list.items.isEmpty {
                await saveItemsToSQLite(list.items, listId: list.id)
            }
        }
    }

    /// Batch-upsert items using INSERT OR IGNORE so synced items survive the next cold launch
    private func saveItemsToSQLite(_ items: [MediaListItem], listId: String) async {
        let records: [[String: Any]] = items.map { item in [
            "id": item.id,
            "list_id": listId,
            "user_id": userId,
            "media_id": item.mediaId,
            "media_type": item.mediaType.rawValue,
            "title": item.title,
            "poster_path": item.posterPath ?? "",
            "runtime": item.runtime as Any,
            "vote_average": item.voteAverage as Any,
            "vote_count": item.voteCount as Any,
            "origin_country": stringArray(item.originCountry),
            "release_date": item.releaseDate ?? "",
            "genres": intArray(item.genres),
            "overview": item.overview ?? "",
            "added_at": ISO8601DateFormatter().string(from: item.addedAt)
        ]}
        await db.performBatchInsert(table: "list_items", records: records)
    }

    @discardableResult
    func fetchLists() async throws -> [MediaList] {
        guard authService.currentUser != nil else {
            loadLists()
            return lists
        }
        let remoteLists = try await supabase.fetchLists()
        applyLists(remoteLists)
        await saveListsToSQLite()
        return remoteLists
    }
    
    @discardableResult
    func createList(name: String, description: String? = nil) async throws -> MediaList {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ListError.invalidName
        }
        guard canCreateList() else {
            throw ListError.maxListsReached(limit: currentCustomListLimit)
        }
        
        guard authService.currentUser != nil else {
            throw ListError.authenticationRequired
        }
        
        // Offline-first: genera l'ID e costruisci la lista LOCALMENTE (prima era remote-first:
        // se offline la creazione falliva del tutto).
        let listId = UUID().uuidString
        let newList = MediaList(
            id: listId,
            name: trimmedName,
            description: description,
            type: .custom,
            createdAt: Date(),
            items: []
        )

        lists.append(newList)
        await ensureListInSQLite(newList)

        // Single remote writer (4.2): la creazione remota va via outbox/SyncEngine
        // (apply_mutations gestisce l'INSERT su `lists`), non più diretta a Supabase.
        let now = ISO8601DateFormatter().string(from: Date())
        try await sync.queueOperation(
            table: "lists",
            operationType: "INSERT",
            recordId: listId,
            payload: [
                "id": listId,
                "user_id": userId,
                "name": trimmedName,
                "description": description ?? "",
                "type": ListType.custom.rawValue,
                "created_at": now,
                "updated_at": now
            ],
            dependsOn: nil
        )

        // Analytics: Track list creation
        AnalyticsService.shared.logListCreated(listType: "custom", listName: trimmedName)
        
        return newList
    }
    
    func updateList(id: String, name: String, description: String? = nil) async throws {
        guard let index = lists.firstIndex(where: { $0.id == id }) else {
            throw ListError.listNotFound
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ListError.invalidName
        }
        let existing = lists[index]
        let updated = MediaList(
            id: existing.id,
            name: trimmedName,
            description: description,
            type: existing.type,
            createdAt: existing.createdAt,
            items: existing.items,
            // Preserva la visibilità: senza questo, rinominare una lista pubblica la riportava
            // a privata in memoria (toggle che "non resta attivo").
            isPublic: existing.isPublic
        )
        lists[index] = updated
        updateDefaultReferences(from: lists)
        notifySoftLimitIfNeeded(for: lists[index])

        // Local-first: ensureListInSQLite usa INSERT OR IGNORE → per un update serve una
        // UPDATE esplicita, altrimenti il nuovo nome non viene persistito localmente.
        _ = db.execute(
            "UPDATE lists SET name = ?, description = ?, updated_at = datetime('now') WHERE id = ?",
            parameters: [trimmedName, description ?? "", id]
        )

        // Single remote writer (4.2): propaga via outbox/SyncEngine, non più diretto a Supabase.
        try await sync.queueOperation(
            table: "lists",
            operationType: "UPDATE",
            recordId: id,
            payload: [
                "id": id,
                "user_id": userId,
                "name": trimmedName,
                "description": description ?? "",
                "type": existing.type.rawValue,
                "created_at": ISO8601DateFormatter().string(from: existing.createdAt),
                "updated_at": ISO8601DateFormatter().string(from: Date())
            ],
            dependsOn: nil
        )
    }
    
    func deleteList(id: String) async throws {
        guard let index = lists.firstIndex(where: { $0.id == id }) else {
            throw ListError.listNotFound
        }
        guard lists[index].type == .custom else {
            throw ListError.defaultListImmutable
        }
        let listType = lists[index].type.rawValue
        
        lists.remove(at: index)

        // Local-first: soft delete locale (awaited, deterministico).
        let success = db.execute(
            "UPDATE lists SET deleted_at = datetime('now') WHERE id = ?",
            parameters: [id]
        )
        if !success {
            Logger.error("[ListManager] Failed to soft-delete list \(id) from SQLite")
        }

        // Single remote writer (4.2): la cancellazione remota va via outbox/SyncEngine,
        // non più diretta a Supabase. apply_mutations fa il soft-delete owner-scoped.
        try await sync.queueOperation(
            table: "lists",
            operationType: "DELETE",
            recordId: id,
            payload: ["id": id, "user_id": userId],
            dependsOn: nil
        )

        // Analytics: Track list deletion
        AnalyticsService.shared.logListDeleted(listType: listType)
    }
    
    func canCreateList() -> Bool {
        let customListCount = lists.filter { $0.type == .custom }.count
        return customListCount < currentCustomListLimit
    }
    
    func customListsCount() -> Int {
        lists.filter { $0.type == .custom }.count
    }
    
    func addToList(
        listId: String,
        movie: Movie,
        mediaType: MediaType,
        analyticsContext: AnalyticsContext? = nil
    ) async throws {
        guard let index = lists.firstIndex(where: { $0.id == listId }) else {
            throw ListError.listNotFound
        }
        
        // Check if user is authenticated for custom lists
        // Anonymous users can only add to watchlist
        if lists[index].type == .custom && authService.currentUser == nil {
            throw ListError.authenticationRequired
        }

        if lists[index].items.contains(where: { $0.mediaId == movie.id && $0.mediaType == mediaType }) {
            throw ListError.itemAlreadyInList
        }

        // Fusione ListsView-Tracking: per una serie TV, watchlist e seen NON sono più righe di
        // `list_items` — sono stato del tracking, e ci si arriva dalla stessa strada delle azioni
        // della tab Tracking. Vale per gli autenticati; un anonimo non ha tracking server e resta
        // sul percorso legacy locale.
        if mediaType == .tv, authService.currentUser != nil,
           lists[index].type == .watchlist || lists[index].type == .seen {
            let targetType = lists[index].type
            if targetType == .watchlist {
                try await trackingActions.addToWatchlist(showId: movie.id)
            } else {
                // "Vista tutta": catalogo + espansione server. Può fallire (rete, catalogo):
                // l'errore risale al chiamante, che già mostra gli errori di addToList.
                try await trackingActions.markSeen(showId: movie.id)
            }

            // Le azioni hanno già fatto il pull mirato: riderivare da SQLite è ciò che rende
            // l'esito visibile — la card compare perché lo specchio è cambiato, non per fede.
            await loadListsFromSQLite()

            AnalyticsService.shared.logItemAddedToList(
                listType: targetType.rawValue,
                mediaType: mediaType.rawValue,
                context: analyticsContext
            )
            PaywallTriggerService.shared.recordSavedToList()
            ReviewPromptManager.shared.recordPositiveAction()
            return
        }

        if lists[index].type == .custom && lists[index].items.count >= Self.maxItemsPerList {
            throw ListError.maxItemsReached(limit: Self.maxItemsPerList)
        }

        let originCountry = movie.productionCountries?.map { $0.iso }
        let genreIds = movie.genreIds ?? movie.genres?.map { $0.id }
        let item = MediaListItem(
            mediaId: movie.id,
            mediaType: mediaType,
            title: movie.title,
            posterPath: movie.posterPath,
            runtime: movie.runtime,
            voteAverage: movie.voteAverage,
            voteCount: movie.voteCount,
            originCountry: originCountry,
            releaseDate: movie.releaseDate,
            genres: genreIds,
            overview: movie.overview
        )

        // Tipo della lista catturato PRIMA dell'await: l'indice non va tenuto attraverso una
        // sospensione (durante `await addItemToSQLite` un evento auth/sync può riassegnare `lists`
        // → `lists[index]` andava out-of-range, crash visto nel fork della watchlist).
        let listType = lists[index].type

        // Always save locally first
        objectWillChange.send()
        lists[index].items.append(item)

        // Single remote writer (4.2): la sincronizzazione remota avviene SOLO via
        // outbox/SyncEngine (vedi addItemToSQLite → queueOperation). Rimossa la scrittura
        // diretta a Supabase (dual-write) che causava id-divergence tra i due path.

        // Also save to local SQLite for offline access.
        // Awaited (non più fire-and-forget) così la persistenza locale e l'enqueue
        // sull'outbox completano prima del ritorno → comportamento deterministico/testabile.
        // L'append in-memory è già avvenuto sopra, quindi la UI resta reattiva.
        await addItemToSQLite(item, listId: listId)

        updateDefaultReferences(from: lists)
        // Ri-risolvi la lista per id DOPO l'await (l'indice può essere stale).
        if let current = lists.first(where: { $0.id == listId }) {
            notifySoftLimitIfNeeded(for: current)
        }
        // Item already saved to SQLite via addItemToSQLite above

        // Analytics: Track item added
        AnalyticsService.shared.logItemAddedToList(
            listType: listType.rawValue,
            mediaType: mediaType.rawValue,
            context: analyticsContext
        )

        PaywallTriggerService.shared.recordSavedToList()

        // Prompt for a review after a successful save action (gated by heuristics)
        ReviewPromptManager.shared.recordPositiveAction()

        // Unificazione TV tracking: marcare una serie come "vista" (lista seen) la porta "in pari"
        // anche nel tracking episodi, così detail page e tracking restano coerenti.
        if listType == .seen, mediaType == .tv {
            EpisodeSeenManager.shared.markShowSeen(showId: movie.id)
        }

        // Prefetch image for offline viewing (watchlist only, WiFi only)
        if listType == .watchlist, let posterPath = item.posterPath {
            Task.detached(priority: .utility) {
                let imageURL = "https://image.tmdb.org/t/p/w500\(posterPath)"
                await ImageCacheService.shared.prefetchImages([imageURL], onWiFiOnly: true)
            }
        }
    }
    
    func canAddToList(listId: String) -> Bool {
        guard let list = lists.first(where: { $0.id == listId }) else { return false }
        if list.type == .custom {
            return list.items.count < Self.maxItemsPerList
        }
        return true // No limit for default lists
    }

    func getItems(listId: String) async throws -> [MediaListItem] {
        if supabase.currentUser != nil {
            let items = try await supabase.fetchListItems(listId: listId)
            if let index = lists.firstIndex(where: { $0.id == listId }) {
                lists[index].items = items
                updateDefaultReferences(from: lists)
            }
            return items
        }
        return lists.first(where: { $0.id == listId })?.items ?? []
    }

    private func notifySoftLimitIfNeeded(for list: MediaList) {
        guard list.type == .custom else { return }
        if list.items.count == Self.softLimitWarningThreshold {
            let message = "lists.softLimitWarning".localized
                .replacingOccurrences(of: "{name}", with: list.name)
                .replacingOccurrences(of: "{limit}", with: "\(Self.softLimitWarningThreshold)")
            softLimitWarningMessage = message
        }
    }
    
    func removeFromList(listId: String, itemId: String) async throws {
        guard let listIndex = lists.firstIndex(where: { $0.id == listId }) else {
            throw ListError.listNotFound
        }

        let removedItem = lists[listIndex].items.first { $0.id == itemId }

        // Fusione ListsView-Tracking: per una serie TV in watchlist/seen la rimozione è
        // un'operazione di tracking, non una riga di `list_items` (che per questi item nemmeno
        // esiste: gli id derivati portano `trackingItemPrefix`).
        if let removedItem, removedItem.mediaType == .tv, authService.currentUser != nil,
           lists[listIndex].type == .watchlist || lists[listIndex].type == .seen {
            if lists[listIndex].type == .watchlist {
                try await trackingActions.removeFromWatchlist(showId: removedItem.mediaId)
            } else {
                // Lapide su tutti gli eventi della serie + dropped, in un'unica RPC: senza il
                // dropped il ricalcolo la farebbe ricomparire come "Da iniziare".
                try await trackingActions.unsee(showId: removedItem.mediaId)
            }
            await loadListsFromSQLite()
            return
        }

        // Percorso legacy (film, anonimi, liste custom). Se sto togliendo una serie dalla lista
        // "seen", la riporto a "non vista" anche nel flag locale (contraltare del markShowSeen).
        if lists[listIndex].type == .seen,
           let removedItem, removedItem.mediaType == .tv {
            EpisodeSeenManager.shared.unmarkShowSeen(showId: removedItem.mediaId)
        }

        // Always remove locally first
        objectWillChange.send()
        lists[listIndex].items.removeAll { $0.id == itemId }
        updateDefaultReferences(from: lists)

        // Single remote writer (4.2): la rimozione remota avviene SOLO via outbox/SyncEngine
        // (vedi removeItemFromSQLite → queueOperation DELETE). Rimossa la scrittura diretta.

        // Also remove from local SQLite.
        // Awaited (non più fire-and-forget) così l'enqueue sull'outbox è deterministico/testabile.
        await removeItemFromSQLite(itemId)
    }
    
    private func removeItemFromSQLite(_ itemId: String) async {
        do {
            // Soft delete in local SQLite
            let success = db.execute("""
                UPDATE list_items
                SET deleted_at = datetime('now'), updated_at = datetime('now')
                WHERE id = ?
            """, parameters: [itemId])
            guard success else {
                throw SQLiteError.queryFailed("Failed to soft-delete list item")
            }
            
            // Queue for sync
            try await sync.queueOperation(
                table: "list_items",
                operationType: "DELETE",
                recordId: itemId,
                payload: ["id": itemId],
                dependsOn: nil
            )
            
            Logger.debug("[ListManager] Removed item \(itemId) from SQLite and queued for sync")

        } catch {
            Logger.error("[ListManager] Failed to remove item from SQLite: \(error)")
        }
    }
    
    func isInList(listId: String, mediaId: Int, mediaType: MediaType) -> Bool {
        guard let list = lists.first(where: { $0.id == listId }) else { return false }
        return list.items.contains(where: { $0.mediaId == mediaId && $0.mediaType == mediaType })
    }
    
    /// Restituisce l'id lista contro cui SCRIVERE gli item, garantendo che esistano sia la riga
    /// `profiles(userId)` sia la riga `lists` (FK con `foreign_keys=ON`). Per le liste core
    /// ritorna l'id CANONICO per (user, type): così una scrittura non punta mai a un id
    /// sintetizzato (race d'avvio tra loadLists/ensureListsInDatabase/sync, o cambio user_id su
    /// login-logout) che l'indice univoco parziale rifiuterebbe di persistere → l'INSERT non
    /// fallisce più in silenzio lasciando l'item solo in memoria (causa "sparisce al riavvio").
    private func persistedListId(forWriting listId: String) async -> String {
        await ensureDeviceProfileInSQLite()
        guard let list = lists.first(where: { $0.id == listId }) else {
            return listId
        }
        if list.type == .custom {
            await ensureListInSQLite(list)
            return list.id
        }
        let rows = (try? await db.queryRaw(
            "SELECT id FROM lists WHERE user_id = ? AND type = ? AND deleted_at IS NULL ORDER BY created_at ASC, id ASC LIMIT 1",
            parameters: [userId, list.type.rawValue]
        )) ?? []
        if let canon = rows.first?["id"] as? String {
            return canon
        }
        await ensureListInSQLite(list)
        return list.id
    }

    private func addItemToSQLite(_ item: MediaListItem, listId: String) async {
        // Risolvi (e garantisci) la riga lista canonica + profilo PRIMA dell'INSERT.
        let targetListId = await persistedListId(forWriting: listId)
        do {
            let addedAt = ISO8601DateFormatter().string(from: item.addedAt)
            let updatedAt = ISO8601DateFormatter().string(from: Date())
            let values: [String: Any] = [
                "id": item.id,
                "list_id": targetListId,
                "user_id": userId,
                "media_id": item.mediaId,
                "media_type": item.mediaType.rawValue,
                "title": item.title,
                "poster_path": item.posterPath ?? "",
                "runtime": item.runtime as Any,
                "vote_average": item.voteAverage as Any,
                "vote_count": item.voteCount as Any,
                "origin_country": stringArray(item.originCountry),
                "release_date": item.releaseDate ?? "",
                "genres": intArray(item.genres),
                "overview": item.overview ?? "",
                "added_at": addedAt,
                "updated_at": updatedAt
            ]
            
            // Insert to local SQLite
            _ = try await db.insert("list_items", values: values)

            var syncPayload = values
            syncPayload["created_at"] = addedAt
            syncPayload["updated_at"] = updatedAt
            
            // Queue for sync
            try await sync.queueOperation(
                table: "list_items",
                operationType: "INSERT",
                recordId: item.id,
                payload: syncPayload,
                dependsOn: nil
            )
            
            Logger.debug("[ListManager] Added item '\(item.title)' to SQLite and queued for sync")

        } catch {
            Logger.error("[ListManager] Failed to add item to SQLite: \(error)")
        }
    }
    
    // MARK: - Public Lists (Fase 1)

    /// Rende pubblica/privata una lista CUSTOM. Mirror locale + outbox (apply_mutations forza
    /// comunque is_public solo per type='custom', difesa in profondità).
    func setListVisibility(listId: String, isPublic: Bool) async throws {
        guard let index = lists.firstIndex(where: { $0.id == listId }) else {
            throw ListError.listNotFound
        }
        guard lists[index].type == .custom else {
            throw ListError.defaultListImmutable
        }

        objectWillChange.send()
        lists[index].isPublic = isPublic
        updateDefaultReferences(from: lists)

        let now = ISO8601DateFormatter().string(from: Date())
        _ = db.execute(
            "UPDATE lists SET is_public = ?, updated_at = datetime('now') WHERE id = ?",
            parameters: [isPublic ? 1 : 0, listId]
        )

        let existing = lists[index]
        try await sync.queueOperation(
            table: "lists",
            operationType: "UPDATE",
            recordId: listId,
            payload: [
                "id": listId,
                "user_id": userId,
                "name": existing.name,
                "description": existing.description ?? "",
                "type": existing.type.rawValue,
                "is_public": isPublic,
                "created_at": ISO8601DateFormatter().string(from: existing.createdAt),
                "updated_at": now
            ],
            dependsOn: nil
        )
    }

    /// Crea una NUOVA lista custom (snapshot scollegato) copiando gli item della sorgente.
    /// Usata per condividere una lista core senza esporre la core stessa. Resta PRIVATA: la
    /// pubblicazione avviene poi dall'editor (toggle visibilità), così non esistono mai liste
    /// pubbliche "Watchlist"/"Seen".
    @discardableResult
    func duplicateAsNewList(from sourceListId: String, name: String? = nil) async throws -> MediaList {
        guard let source = lists.first(where: { $0.id == sourceListId }) else {
            throw ListError.listNotFound
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = (trimmed?.isEmpty == false ? trimmed! : source.displayName)
        let newList = try await createList(name: newName, description: source.description)
        for item in source.items {
            try? await addToList(listId: newList.id, movie: item.asMovie(), mediaType: item.mediaType)
        }
        return lists.first(where: { $0.id == newList.id }) ?? newList
    }

    private func existingFollowId(listId: String) async -> String? {
        let rows = (try? await db.queryRaw(
            "SELECT id FROM list_follows WHERE user_id = ? AND list_id = ?",
            parameters: [userId, listId]
        )) ?? []
        return rows.first?["id"] as? String
    }

    /// Segue una lista pubblica (bookmark live). Riusa la riga locale per (user, list).
    func followList(listId: String) async throws {
        guard authService.currentUser != nil else { throw ListError.authenticationRequired }
        let now = ISO8601DateFormatter().string(from: Date())
        let followId = await existingFollowId(listId: listId) ?? UUID().uuidString
        _ = db.execute("""
            INSERT INTO list_follows (id, user_id, list_id, created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, NULL)
            ON CONFLICT(user_id, list_id) DO UPDATE SET deleted_at = NULL, updated_at = ?
        """, parameters: [followId, userId, listId, now, now, now])

        try await sync.queueOperation(
            table: "list_follows",
            operationType: "INSERT",
            recordId: followId,
            payload: ["id": followId, "user_id": userId, "list_id": listId, "created_at": now],
            dependsOn: nil
        )
    }

    func unfollowList(listId: String) async throws {
        guard let followId = await existingFollowId(listId: listId) else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        _ = db.execute(
            "UPDATE list_follows SET deleted_at = ?, updated_at = ? WHERE id = ?",
            parameters: [now, now, followId]
        )
        try await sync.queueOperation(
            table: "list_follows",
            operationType: "DELETE",
            recordId: followId,
            payload: ["id": followId, "user_id": userId],
            dependsOn: nil
        )
    }

    /// Blocca un utente: le sue liste pubbliche spariscono dal feed (lato server le RPC le filtrano).
    func blockUser(_ blockedUserId: String) async throws {
        guard authService.currentUser != nil else { throw ListError.authenticationRequired }
        guard blockedUserId != userId else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        let rows = (try? await db.queryRaw(
            "SELECT id FROM user_blocks WHERE user_id = ? AND blocked_user_id = ?",
            parameters: [userId, blockedUserId]
        )) ?? []
        let blockId = rows.first?["id"] as? String ?? UUID().uuidString
        _ = db.execute("""
            INSERT INTO user_blocks (id, user_id, blocked_user_id, created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, NULL)
            ON CONFLICT(user_id, blocked_user_id) DO UPDATE SET deleted_at = NULL, updated_at = ?
        """, parameters: [blockId, userId, blockedUserId, now, now, now])

        try await sync.queueOperation(
            table: "user_blocks",
            operationType: "INSERT",
            recordId: blockId,
            payload: ["id": blockId, "user_id": userId, "blocked_user_id": blockedUserId, "created_at": now],
            dependsOn: nil
        )
    }

    /// Segnala una lista pubblica. Idempotente per (utente, lista); oltre soglia il server la nasconde.
    func reportList(listId: String, reason: String? = nil) async throws {
        guard authService.currentUser != nil else { throw ListError.authenticationRequired }
        let now = ISO8601DateFormatter().string(from: Date())
        let reportId = UUID().uuidString
        _ = db.execute("""
            INSERT OR IGNORE INTO list_reports (id, user_id, list_id, reason, created_at)
            VALUES (?, ?, ?, ?, ?)
        """, parameters: [reportId, userId, listId, reason ?? "", now])

        try await sync.queueOperation(
            table: "list_reports",
            operationType: "INSERT",
            recordId: reportId,
            payload: ["id": reportId, "user_id": userId, "list_id": listId, "reason": reason ?? "", "created_at": now],
            dependsOn: nil
        )
    }

    // MARK: - Helper Methods

    
    private func parseStringArray(_ json: String?) -> [String]? {
        guard let json = json,
              let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return array
    }
    
    private func parseIntArray(_ json: String?) -> [Int]? {
        guard let json = json,
              let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([Int].self, from: data) else {
            return nil
        }
        return array
    }
    
    private func stringArray(_ array: [String]?) -> String {
        guard let array = array,
              let data = try? JSONEncoder().encode(array),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }
    
    private func intArray(_ array: [Int]?) -> String {
        guard let array = array,
              let data = try? JSONEncoder().encode(array),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }
}
