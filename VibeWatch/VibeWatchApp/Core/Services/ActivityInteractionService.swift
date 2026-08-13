import Foundation

// MARK: - Modello

/// Un commento del feed attività, già pronto per la UI del foglio. Nasce da una riga di
/// `get_activity_comments` o dallo specchio locale — la forma è la stessa nei due casi,
/// così offline e online disegnano identico.
struct ActivityComment: Identifiable, Equatable {
    let id: UUID
    let activityId: UUID
    let userId: UUID
    let username: String?
    let displayName: String?
    let avatarUrl: String?
    let parentId: UUID?
    /// `nil` per le lapidi: un commento cancellato con reply vive resta nel filo senza testo.
    let content: String?
    let isDeleted: Bool
    let createdAt: Date
    var likeCount: Int
    var likedByMe: Bool
    /// Vero finché la riga non ha raggiunto il server (composta offline, in coda di replay).
    var isPending: Bool

    var isReply: Bool { parentId != nil }
}

// MARK: - Errori

/// Gli errori "parlati" delle interazioni. `contentUnavailable` traduce i P0002 del server
/// (activity/comment/content_not_available), che per scelta coprono anche cancellato, privato
/// e bloccato nei due versi: non ritentabile per definizione, l'unica risposta onesta è
/// "questo contenuto non c'è più".
enum ActivityInteractionError: LocalizedError {
    case notAuthenticated
    case contentUnavailable
    case invalidContent

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "auth.gate.accountRequired".localized
        case .contentUnavailable: return "social.comments.unavailable".localized
        case .invalidContent: return "social.comments.postFailed".localized
        }
    }
}

// MARK: - Servizio

/// Le interazioni del feed attività: like alla card, commenti (add/delete), like ai commenti,
/// lettura del filo, segnalazioni. Sulla falsariga di `ClipCommentService` (ottimismo locale +
/// RPC + riconciliazione col vero del server), con una differenza deliberata sull'offline:
///
/// - Le tabelle remote NON hanno grant diretti né rami in `apply_mutations`: ogni scrittura è
///   RPC-only, e NIENTE passa da `SyncEngine.queueOperation` — una mutazione accodata lì
///   morirebbe in silenzio in `sync_rejected_mutations`.
/// - I TOGGLE non si ritentano mai alla cieca: `toggle_activity_like` inverte lo stato, quindi
///   un retry di un toggle già riuscito lo DISFA. Al fallimento si torna allo stato di prima
///   (rollback) e lo si dice; nessuna coda.
/// - Add/delete commento invece viaggiano con id generato dal client e sul server sono upsert:
///   il replay è idempotente per costruzione, quindi (solo) loro finiscono in
///   `activity_pending_ops` e si rigiocano in ordine alla prima occasione utile.
@MainActor
final class ActivityInteractionService: ObservableObject {
    static let shared = ActivityInteractionService()

    private let sqlite: SQLiteService
    private let supabase: SupabaseService

    /// Replay già in corso: le chiamate opportunistiche non si accavallano.
    private var isReplaying = false
    /// Oltre questa soglia un op pendente si butta: un errore che persiste per otto replay
    /// non è rete, è un contenuto che il server non vuole — tenerlo intaserebbe la coda.
    private static let maxReplayAttempts = 8

    /// Il cursore locale scrive i frazionali: il keyset del server confronta timestamptz pieni
    /// e un ISO troncato ai secondi farebbe saltare (o ripetere) righe al confronto.
    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let isoPlain = ISO8601DateFormatter()

    init(sqlite: SQLiteService = .shared, supabase: SupabaseService = .shared) {
        self.sqlite = sqlite
        self.supabase = supabase
    }

    // MARK: - Like alla card

    /// Toggle del like a un'attività. Ottimismo locale, poi il server risponde con lo stato
    /// VERO (liked, like_count) e quello vince. Al fallimento: rollback e rilancio — mai una
    /// coda, per la ragione scritta in testa al file.
    func toggleActivityLike(activityId: UUID) async throws -> (liked: Bool, likeCount: Int) {
        guard let uid = currentUserId() else { throw ActivityInteractionError.notAuthenticated }
        let aid = activityId.uuidString.lowercased()

        // L'id del like è stabile per (attività, utente): il server rianima la stessa riga al
        // re-like, quindi si ricorda, non si rigenera.
        let existingId = await existingLikeId(table: "activity_likes", column: "activity_id",
                                              key: aid, userId: uid)
        let likeId = existingId ?? UUID().uuidString.lowercased()
        let wasLiked = existingId != nil

        setActivityLikeRow(activityId: aid, userId: uid, likeId: likeId,
                           liked: !wasLiked, synced: false)

        do {
            let result = try await supabase.toggleActivityLike(
                activityId: activityId, likeId: UUID(uuidString: likeId) ?? UUID())
            setActivityLikeRow(activityId: aid, userId: uid, likeId: likeId,
                               liked: result.liked, synced: true)
            return (result.liked, result.likeCount)
        } catch {
            // Rollback: l'ottimismo si ritira, non si accoda.
            setActivityLikeRow(activityId: aid, userId: uid, likeId: likeId,
                               liked: wasLiked, synced: false)
            throw mapped(error)
        }
    }

    // MARK: - Lettura del filo

    /// Una pagina di commenti (ascendente, cursore in avanti). Online: la pagina si specchia in
    /// locale e si restituisce; offline: risponde lo specchio, con i pendenti in coda. I
    /// commenti composti offline si appendono solo all'ULTIMA pagina — in mezzo a un cursore
    /// vivo sarebbero righe fuori ordine.
    func comments(activityId: UUID, after: (Date, UUID)?,
                  limit: Int = 50) async throws -> [ActivityComment] {
        await replayPendingOps()
        let aid = activityId.uuidString.lowercased()

        do {
            let rows = try await supabase.fetchActivityComments(
                activityId: activityId, after: after, limit: limit)
            mirror(rows, activityId: aid, isFirstPage: after == nil)

            var page = rows.map { comment(from: $0, activityId: activityId) }
            if rows.count < limit {
                let pending = await pendingLocalComments(
                    activityId: activityId, excluding: Set(page.map(\.id)))
                page.append(contentsOf: pending)
            }
            return page
        } catch {
            if Self.isContentUnavailable(error) { throw ActivityInteractionError.contentUnavailable }
            // Offline o guasto transitorio: lo specchio locale tiene in piedi il foglio.
            Logger.warning("[ActivityInteraction] Comments fetch failed, serving local mirror: \(error.localizedDescription)")
            return await localComments(activityId: activityId, after: after, limit: limit)
        }
    }

    // MARK: - Commenti

    /// Nuovo commento (o reply, un livello). Scrive subito lo specchio (il filo lo mostra
    /// all'istante), poi prova il server; se la rete manca, l'op finisce in coda e si rigioca
    /// con lo STESSO id — sul server è un upsert, quindi mai un doppione.
    func addComment(activityId: UUID, content: String,
                    parentId: UUID?) async throws -> ActivityComment {
        guard let uid = currentUserId() else { throw ActivityInteractionError.notAuthenticated }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1000 else {
            throw ActivityInteractionError.invalidContent
        }

        let commentId = UUID()
        let now = Date()
        let user = AuthService.shared.currentUser
        var comment = ActivityComment(
            id: commentId,
            activityId: activityId,
            userId: UUID(uuidString: uid) ?? UUID(),
            username: nil,
            displayName: user?.displayName,
            avatarUrl: user?.avatarURL,
            parentId: parentId,
            content: trimmed,
            isDeleted: false,
            createdAt: now,
            likeCount: 0,
            likedByMe: false,
            isPending: true)

        insertLocalComment(comment, userId: uid)

        do {
            _ = try await supabase.addActivityComment(
                activityId: activityId, content: trimmed,
                commentId: commentId, parentId: parentId)
            markSynced(table: "activity_comments", idColumn: "id",
                       id: commentId.uuidString.lowercased())
            comment.isPending = false
            return comment
        } catch {
            if Self.isContentUnavailable(error) {
                // La card non c'è più (o un blocco è comparso): il commento ottimistico si
                // ritira — lasciarlo nello specchio sarebbe un fantasma senza destinazione.
                deleteLocalComment(id: commentId.uuidString.lowercased())
                throw ActivityInteractionError.contentUnavailable
            }
            var payload: [String: Any] = [
                "activity_id": activityId.uuidString.lowercased(),
                "comment_id": commentId.uuidString.lowercased(),
                "content": trimmed
            ]
            if let parentId { payload["parent_id"] = parentId.uuidString.lowercased() }
            queuePendingOp(type: "comment_add", payload: payload)
            Logger.debug("[ActivityInteraction] Comment queued for replay (offline)")
            return comment
        }
    }

    /// Cancella un commento. La legittimazione la decide il server (proprietario del commento
    /// O della card); qui si specchia l'esito e, a rete assente, si accoda il replay — anche
    /// il delete è idempotente: rigiocarlo su un commento già sparito risponde P0002, che per
    /// un delete è l'esito desiderato, non un errore.
    func deleteComment(commentId: UUID) async throws {
        let cid = commentId.uuidString.lowercased()
        markLocalCommentDeleted(id: cid)

        do {
            try await supabase.deleteActivityComment(commentId: commentId)
            markSynced(table: "activity_comments", idColumn: "id", id: cid)
        } catch {
            if Self.isContentUnavailable(error) {
                // Già sparito lato server: è quello che si voleva.
                markSynced(table: "activity_comments", idColumn: "id", id: cid)
                return
            }
            queuePendingOp(type: "comment_delete", payload: ["comment_id": cid])
            Logger.debug("[ActivityInteraction] Comment delete queued for replay (offline)")
        }
    }

    // MARK: - Like ai commenti

    /// Toggle del like a un commento: stessa disciplina del like alla card — ottimismo,
    /// riconciliazione col server, rollback al fallimento, MAI una coda.
    func toggleCommentLike(commentId: UUID) async throws -> (liked: Bool, likeCount: Int) {
        guard let uid = currentUserId() else { throw ActivityInteractionError.notAuthenticated }
        let cid = commentId.uuidString.lowercased()

        let existingId = await existingLikeId(table: "activity_comment_likes",
                                              column: "comment_id", key: cid, userId: uid)
        let likeId = existingId ?? UUID().uuidString.lowercased()
        let wasLiked = existingId != nil

        setCommentLikeRow(commentId: cid, userId: uid, likeId: likeId,
                          liked: !wasLiked, wasLiked: wasLiked, likeCount: nil, synced: false)

        do {
            let result = try await supabase.toggleActivityCommentLike(
                commentId: commentId, likeId: UUID(uuidString: likeId) ?? UUID())
            setCommentLikeRow(commentId: cid, userId: uid, likeId: likeId,
                              liked: result.liked, wasLiked: !wasLiked,
                              likeCount: result.likeCount, synced: true)
            return (result.liked, result.likeCount)
        } catch {
            setCommentLikeRow(commentId: cid, userId: uid, likeId: likeId,
                              liked: wasLiked, wasLiked: !wasLiked, likeCount: nil, synced: false)
            throw mapped(error)
        }
    }

    // MARK: - Segnalazioni

    /// Segnala una review o un commento. Idempotente sul server: nessuno stato locale, nessuna
    /// coda — se fallisce lo si dice e l'utente ripreme, senza rischi di doppioni.
    func report(type: ReportableContentType, contentId: UUID, reason: String? = nil) async throws {
        do {
            try await supabase.reportContent(type: type, id: contentId, reason: reason)
        } catch {
            throw mapped(error)
        }
    }

    // MARK: - Replay della coda

    /// Rigioca gli op pendenti in ordine di nascita. Si ferma al primo fallimento di rete
    /// (l'ordine è parte del significato: un delete non deve scavalcare l'add che cancella);
    /// gli esiti non ritentabili (P0002) chiudono l'op invece di incastrare la coda.
    func replayPendingOps() async {
        guard !isReplaying else { return }
        guard supabase.isAuthenticated else { return }
        isReplaying = true
        defer { isReplaying = false }

        let rows = (try? await sqlite.queryRaw("""
            SELECT op_id, op_type, payload_json, attempts FROM activity_pending_ops
            ORDER BY created_at ASC, op_id ASC
        """)) ?? []

        for row in rows {
            guard let opId = row["op_id"] as? String,
                  let opType = row["op_type"] as? String,
                  let json = row["payload_json"] as? String,
                  let payload = (try? JSONSerialization.jsonObject(
                    with: Data(json.utf8))) as? [String: Any] else {
                // Un op illeggibile non guarisce da solo: via.
                if let opId = row["op_id"] as? String { deletePendingOp(opId) }
                continue
            }

            do {
                try await replay(opType: opType, payload: payload)
                deletePendingOp(opId)
            } catch {
                if Self.isContentUnavailable(error) {
                    // Non ritentabile: per un add il contenuto ottimistico si ritira,
                    // per un delete l'assenza È il risultato.
                    if opType == "comment_add", let cid = payload["comment_id"] as? String {
                        deleteLocalComment(id: cid)
                    }
                    deletePendingOp(opId)
                    continue
                }
                let attempts = (row["attempts"] as? Int ?? 0) + 1
                if attempts >= Self.maxReplayAttempts {
                    Logger.warning("[ActivityInteraction] Dropping pending op \(opType) after \(attempts) attempts")
                    if opType == "comment_add", let cid = payload["comment_id"] as? String {
                        deleteLocalComment(id: cid)
                    }
                    deletePendingOp(opId)
                } else {
                    _ = sqlite.execute(
                        "UPDATE activity_pending_ops SET attempts = ? WHERE op_id = ?",
                        parameters: [attempts, opId])
                }
                break // rete assente: il resto della coda aspetta, in ordine
            }
        }
    }

    private func replay(opType: String, payload: [String: Any]) async throws {
        switch opType {
        case "comment_add":
            guard let aid = (payload["activity_id"] as? String).flatMap(UUID.init(uuidString:)),
                  let cid = (payload["comment_id"] as? String).flatMap(UUID.init(uuidString:)),
                  let content = payload["content"] as? String else { return }
            let parentId = (payload["parent_id"] as? String).flatMap(UUID.init(uuidString:))
            _ = try await supabase.addActivityComment(
                activityId: aid, content: content, commentId: cid, parentId: parentId)
            markSynced(table: "activity_comments", idColumn: "id",
                       id: cid.uuidString.lowercased())
        case "comment_delete":
            guard let cid = (payload["comment_id"] as? String).flatMap(UUID.init(uuidString:))
            else { return }
            try await supabase.deleteActivityComment(commentId: cid)
            markSynced(table: "activity_comments", idColumn: "id",
                       id: cid.uuidString.lowercased())
        default:
            Logger.warning("[ActivityInteraction] Unknown pending op type '\(opType)' — dropping")
        }
    }

    // MARK: - Classificazione errori

    /// I P0002 del server ('activity/comment/content_not_available') viaggiano sia come
    /// `PostgrestError` (client tipizzato) sia dentro il body di `SupabaseError.httpError`
    /// (callRPC): la stringa è l'unico denominatore comune tra i due canali.
    static func isContentUnavailable(_ error: Error) -> Bool {
        if case ActivityInteractionError.contentUnavailable = error { return true }
        return String(describing: error).lowercased().contains("not_available")
    }

    private func mapped(_ error: Error) -> Error {
        Self.isContentUnavailable(error) ? ActivityInteractionError.contentUnavailable : error
    }

    // MARK: - Specchio locale: like

    private func currentUserId() -> String? {
        supabase.currentUser?.id.lowercased()
    }

    private func existingLikeId(table: String, column: String,
                                key: String, userId: String) async -> String? {
        let rows = try? await sqlite.queryRaw(
            "SELECT id FROM \(table) WHERE \(column) = ? AND user_id = ? LIMIT 1",
            parameters: [key, userId])
        return rows?.first?["id"] as? String
    }

    private func setActivityLikeRow(activityId: String, userId: String, likeId: String,
                                    liked: Bool, synced: Bool) {
        let now = isoFractional.string(from: Date())
        if liked {
            _ = sqlite.execute("""
                INSERT INTO activity_likes (id, activity_id, user_id, created_at, synced_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(activity_id, user_id) DO UPDATE SET
                    synced_at = excluded.synced_at
            """, parameters: [likeId, activityId, userId, now, synced ? now : NSNull()])
        } else {
            _ = sqlite.execute(
                "DELETE FROM activity_likes WHERE activity_id = ? AND user_id = ?",
                parameters: [activityId, userId])
        }
    }

    private func setCommentLikeRow(commentId: String, userId: String, likeId: String,
                                   liked: Bool, wasLiked: Bool, likeCount: Int?, synced: Bool) {
        let now = isoFractional.string(from: Date())
        if liked {
            _ = sqlite.execute("""
                INSERT INTO activity_comment_likes (id, comment_id, user_id, created_at, synced_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(comment_id, user_id) DO UPDATE SET
                    synced_at = excluded.synced_at
            """, parameters: [likeId, commentId, userId, now, synced ? now : NSNull()])
        } else {
            _ = sqlite.execute(
                "DELETE FROM activity_comment_likes WHERE comment_id = ? AND user_id = ?",
                parameters: [commentId, userId])
        }

        // Il contatore sullo specchio del commento: il valore del server quando c'è, un
        // aggiustamento relativo quando si è ancora nell'ottimismo.
        if let likeCount {
            _ = sqlite.execute("""
                UPDATE activity_comments SET like_count = ?, liked_by_me = ? WHERE id = ?
            """, parameters: [likeCount, liked ? 1 : 0, commentId])
        } else if liked != wasLiked {
            _ = sqlite.execute("""
                UPDATE activity_comments
                SET like_count = MAX(0, like_count + ?), liked_by_me = ?
                WHERE id = ?
            """, parameters: [liked ? 1 : -1, liked ? 1 : 0, commentId])
        }
    }

    // MARK: - Specchio locale: commenti

    /// Specchia una pagina del server. Alla PRIMA pagina le righe sincronizzate dell'attività
    /// si azzerano prima dell'upsert: un commento sparito sul server (cancellato senza reply
    /// vive) deve sparire anche qui — l'upsert da solo sa riempire, mai togliere. I pendenti
    /// (synced_at NULL) si salvano: sono verità locale in attesa di replay.
    private func mirror(_ rows: [ActivityCommentRow], activityId: String, isFirstPage: Bool) {
        if isFirstPage {
            _ = sqlite.execute("""
                DELETE FROM activity_comments
                WHERE activity_id = ? AND synced_at IS NOT NULL
            """, parameters: [activityId])
        }
        let now = isoFractional.string(from: Date())
        for row in rows {
            _ = sqlite.execute("""
                INSERT INTO activity_comments (
                    id, activity_id, user_id, parent_id, content, username, display_name,
                    avatar_url, like_count, liked_by_me, is_deleted, created_at, synced_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    content = excluded.content,
                    username = excluded.username,
                    display_name = excluded.display_name,
                    avatar_url = excluded.avatar_url,
                    like_count = excluded.like_count,
                    liked_by_me = excluded.liked_by_me,
                    is_deleted = excluded.is_deleted,
                    synced_at = excluded.synced_at
            """, parameters: [
                row.commentId.uuidString.lowercased(),
                activityId,
                row.userId.uuidString.lowercased(),
                row.parentId?.uuidString.lowercased() ?? NSNull(),
                row.content ?? NSNull(),
                row.username ?? NSNull(),
                row.displayName ?? NSNull(),
                row.avatarUrl ?? NSNull(),
                row.likeCount,
                row.likedByMe ? 1 : 0,
                row.isDeleted ? 1 : 0,
                isoFractional.string(from: row.createdAt),
                now
            ])
        }
    }

    private func insertLocalComment(_ comment: ActivityComment, userId: String) {
        _ = sqlite.execute("""
            INSERT INTO activity_comments (
                id, activity_id, user_id, parent_id, content, username, display_name,
                avatar_url, like_count, liked_by_me, is_deleted, created_at, synced_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, ?, NULL)
        """, parameters: [
            comment.id.uuidString.lowercased(),
            comment.activityId.uuidString.lowercased(),
            userId,
            comment.parentId?.uuidString.lowercased() ?? NSNull(),
            comment.content ?? NSNull(),
            comment.username ?? NSNull(),
            comment.displayName ?? NSNull(),
            comment.avatarUrl ?? NSNull(),
            isoFractional.string(from: comment.createdAt)
        ])
    }

    private func markLocalCommentDeleted(id: String) {
        _ = sqlite.execute("""
            UPDATE activity_comments
            SET is_deleted = 1, content = NULL, synced_at = NULL
            WHERE id = ?
        """, parameters: [id])
    }

    private func deleteLocalComment(id: String) {
        _ = sqlite.execute("DELETE FROM activity_comments WHERE id = ?", parameters: [id])
    }

    private func markSynced(table: String, idColumn: String, id: String) {
        let now = isoFractional.string(from: Date())
        _ = sqlite.execute("UPDATE \(table) SET synced_at = ? WHERE \(idColumn) = ?",
                           parameters: [now, id])
    }

    /// Il filo dallo specchio, stessa forma (ascendente, keyset) della RPC: offline la
    /// paginazione continua a funzionare sulle righe già viste.
    private func localComments(activityId: UUID, after: (Date, UUID)?,
                               limit: Int) async -> [ActivityComment] {
        let aid = activityId.uuidString.lowercased()
        var sql = """
            SELECT id, activity_id, user_id, parent_id, content, username, display_name,
                   avatar_url, like_count, liked_by_me, is_deleted, created_at, synced_at
            FROM activity_comments
            WHERE activity_id = ?
        """
        var parameters: [Any] = [aid]
        if let after {
            sql += " AND (created_at > ? OR (created_at = ? AND id > ?))"
            let cursor = isoFractional.string(from: after.0)
            parameters.append(contentsOf: [cursor, cursor, after.1.uuidString.lowercased()])
        }
        sql += " ORDER BY created_at ASC, id ASC LIMIT ?"
        parameters.append(limit)

        let rows = (try? await sqlite.queryRaw(sql, parameters: parameters)) ?? []
        return rows.compactMap { localComment(from: $0) }
    }

    /// I commenti ancora in coda di replay, da appendere all'ultima pagina del filo.
    private func pendingLocalComments(activityId: UUID,
                                      excluding: Set<UUID>) async -> [ActivityComment] {
        let rows = (try? await sqlite.queryRaw("""
            SELECT id, activity_id, user_id, parent_id, content, username, display_name,
                   avatar_url, like_count, liked_by_me, is_deleted, created_at, synced_at
            FROM activity_comments
            WHERE activity_id = ? AND synced_at IS NULL AND is_deleted = 0
            ORDER BY created_at ASC, id ASC
        """, parameters: [activityId.uuidString.lowercased()])) ?? []
        return rows.compactMap { localComment(from: $0) }
            .filter { !excluding.contains($0.id) }
    }

    // MARK: - Mapping

    private func comment(from row: ActivityCommentRow, activityId: UUID) -> ActivityComment {
        ActivityComment(
            id: row.commentId,
            activityId: activityId,
            userId: row.userId,
            username: row.username,
            displayName: row.displayName,
            avatarUrl: row.avatarUrl,
            parentId: row.parentId,
            content: row.content,
            isDeleted: row.isDeleted,
            createdAt: row.createdAt,
            likeCount: row.likeCount,
            likedByMe: row.likedByMe,
            isPending: false)
    }

    private func localComment(from row: [String: Any]) -> ActivityComment? {
        guard let idString = row["id"] as? String, let id = UUID(uuidString: idString),
              let aidString = row["activity_id"] as? String,
              let activityId = UUID(uuidString: aidString),
              let uidString = row["user_id"] as? String,
              let userId = UUID(uuidString: uidString),
              let createdAtString = row["created_at"] as? String,
              let createdAt = isoFractional.date(from: createdAtString)
                ?? isoPlain.date(from: createdAtString) else { return nil }

        return ActivityComment(
            id: id,
            activityId: activityId,
            userId: userId,
            username: row["username"] as? String,
            displayName: row["display_name"] as? String,
            avatarUrl: row["avatar_url"] as? String,
            parentId: (row["parent_id"] as? String).flatMap(UUID.init(uuidString:)),
            content: row["content"] as? String,
            isDeleted: (row["is_deleted"] as? Int ?? 0) != 0,
            createdAt: createdAt,
            likeCount: row["like_count"] as? Int ?? 0,
            likedByMe: (row["liked_by_me"] as? Int ?? 0) != 0,
            isPending: row["synced_at"] == nil || row["synced_at"] is NSNull)
    }

    // MARK: - Coda

    private func queuePendingOp(type: String, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        // INSERT semplice, niente OR REPLACE: l'op_id nasce nuovo qui e non può collidere —
        // e il REPLACE INTO a mano è il footgun di STAB-001 (lo vieta la characterization).
        _ = sqlite.execute("""
            INSERT INTO activity_pending_ops (op_id, op_type, payload_json, attempts, created_at)
            VALUES (?, ?, ?, 0, ?)
        """, parameters: [UUID().uuidString.lowercased(), type, json,
                          isoFractional.string(from: Date())])
    }

    private func deletePendingOp(_ opId: String) {
        _ = sqlite.execute("DELETE FROM activity_pending_ops WHERE op_id = ?",
                           parameters: [opId])
    }
}
