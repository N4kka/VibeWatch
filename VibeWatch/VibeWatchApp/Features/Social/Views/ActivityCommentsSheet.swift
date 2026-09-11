import SwiftUI

/// Il foglio dei commenti di una card del feed attività.
///
/// NON riusa `CommentsListView`/`CommentRowView`/`CommentInputView`: quei tre sono saldati a
/// `ClipComment` e a `ClipCommentService` (tipi nelle firme, chiamate al servizio dentro le
/// view) e hanno una semantica diversa — discendente con reply espandibili e conteggiate,
/// contro l'ascendente keyset con lapidi di `get_activity_comments`. Scollarli avrebbe
/// significato riscrivere le firme di tutti e tre e ritestare ClipsView per zero guadagno.
/// L'anatomia visiva però è la stessa (avatar 32, nome • tempo, testo, cuore + reply,
/// composer in basso): due fogli di commenti nell'app devono sembrare parenti.
struct ActivityCommentsSheet: View {
    let activityId: UUID
    /// Il padrone della card: può cancellare QUALSIASI commento sotto casa sua (il server
    /// lo verifica comunque — qui si decide solo se mostrare il tasto).
    let activityOwnerId: UUID
    /// Il conteggio di partenza della card: il foglio riporta fuori partenza + delta, che
    /// resta giusto anche quando il filo non è caricato per intero.
    let initialCommentCount: Int
    var onCommentCountChanged: ((Int) -> Void)? = nil
    /// Solo per analytics: il tipo della card (rated/watched/...), se chi apre il foglio lo sa.
    var analyticsActivityType: String? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var comments: [ActivityComment] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasMore = false
    @State private var errorMessage: String?

    @State private var composerText = ""
    @State private var isPosting = false
    @State private var replyingTo: ActivityComment?
    @FocusState private var composerFocused: Bool

    @State private var deleteTarget: ActivityComment?
    @State private var reportTarget: ActivityComment?

    /// Somma algebrica dei commenti postati/cancellati in questa sessione del foglio.
    @State private var countDelta = 0

    /// Semina per i #Preview: il servizio vero parla con rete e SQLite.
    var previewComments: [ActivityComment]?

    private let pageSize = 50
    private let maxCharacters = 1000

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            content
            Divider().overlay(Color.white.opacity(0.08))
            composer
        }
        .background(Color.theme.background.ignoresSafeArea())
        .task {
            if let previewComments {
                comments = previewComments
                return
            }
            if comments.isEmpty { await loadInitial() }
        }
        .confirmationDialog(
            "social.comments.deleteConfirm".localized,
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("common.delete".localized, role: .destructive) {
                if let target = deleteTarget {
                    Task { await delete(target) }
                }
                deleteTarget = nil
            }
            Button("common.cancel".localized, role: .cancel) { deleteTarget = nil }
        }
        .confirmationDialog(
            "social.report.confirmTitle".localized,
            isPresented: Binding(
                get: { reportTarget != nil },
                set: { if !$0 { reportTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("social.report.confirm".localized, role: .destructive) {
                if let target = reportTarget {
                    Task { await report(target) }
                }
                reportTarget = nil
            }
            Button("common.cancel".localized, role: .cancel) { reportTarget = nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("social.comments.title".localized)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.theme.textPrimary)

            if initialCommentCount + countDelta > 0 {
                Text("(\(initialCommentCount + countDelta))")
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.theme.textSecondary)
            }
            .accessibilityLabel(Text("common.close".localized))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Contenuto

    @ViewBuilder
    private var content: some View {
        if isLoading && comments.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = errorMessage, comments.isEmpty {
            errorState(error)
        } else if comments.isEmpty {
            emptyState
        } else {
            thread
        }
    }

    /// Un livello di reply e basta, come sul server: le reply si disegnano rientrate sotto il
    /// loro top-level. L'ordine ascendente garantisce che il padre compaia sempre prima delle
    /// figlie (una reply nasce dopo il suo padre, e le lapidi con reply vive restano nel filo).
    private var thread: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(topLevelComments) { comment in
                    row(for: comment, isReply: false)
                    ForEach(replies(of: comment)) { reply in
                        row(for: reply, isReply: true)
                    }
                }

                if hasMore {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        if isLoadingMore {
                            ProgressView().padding(.vertical, 12)
                        } else {
                            Text("social.comments.loadMore".localized)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.theme.accentOrange)
                                .padding(.vertical, 12)
                        }
                    }
                    .disabled(isLoadingMore)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func row(for comment: ActivityComment, isReply: Bool) -> some View {
        ActivityCommentThreadRow(
            comment: comment,
            isReply: isReply,
            onLike: { Task { await toggleLike(comment) } },
            onReply: {
                replyingTo = comment
                composerFocused = true
            })
        .contextMenu {
            if !comment.isDeleted {
                if canDelete(comment) {
                    Button(role: .destructive) {
                        deleteTarget = comment
                    } label: {
                        Label("common.delete".localized, systemImage: "trash")
                    }
                }
                if !isMine(comment) {
                    Button {
                        reportTarget = comment
                    } label: {
                        Label("social.comments.report".localized, systemImage: "flag")
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 30))
                .foregroundColor(.theme.textSecondary)
            Text("social.comments.empty".localized)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
            Text("social.comments.beFirst".localized)
                .font(.system(size: 13))
                .foregroundColor(.theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(.theme.accentOrange)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("common.tryAgain".localized) {
                Task { await loadInitial() }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.theme.accentOrange)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if let replying = replyingTo {
                HStack {
                    Text(String(format: "social.comments.replyingTo".localized,
                                replying.displayName ?? replying.username ?? ""))
                        .font(.system(size: 12))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Button("common.cancel".localized) { replyingTo = nil }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.theme.accentOrange)
                }
                .padding(.horizontal, 16)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    replyingTo != nil
                        ? "social.comments.replyPlaceholder".localized
                        : "social.comments.placeholder".localized,
                    text: $composerText,
                    axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(.theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .focused($composerFocused)
                .lineLimit(1...5)
                .disabled(isPosting)

                Button(action: { Task { await post() } }) {
                    if isPosting {
                        ProgressView()
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(canPost ? .theme.accentOrange : .theme.textSecondary)
                    }
                }
                .disabled(!canPost || isPosting)
                .accessibilityLabel(Text("social.comments.send".localized))
            }
            .padding(.horizontal, 16)

            // Il contatore compare solo quando serve: sotto i 900 caratteri è rumore.
            if composerText.count > maxCharacters - 100 {
                HStack {
                    Spacer()
                    Text("\(composerText.count)/\(maxCharacters)")
                        .font(.system(size: 11))
                        .foregroundColor(composerText.count > maxCharacters
                                         ? .red : .theme.textSecondary)
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 10)
    }

    private var canPost: Bool {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && composerText.count <= maxCharacters
    }

    // MARK: - Derivazioni

    private var topLevelComments: [ActivityComment] {
        comments.filter { $0.parentId == nil }
    }

    private func replies(of comment: ActivityComment) -> [ActivityComment] {
        comments.filter { $0.parentId == comment.id }
    }

    private var currentUserId: String? {
        SupabaseService.shared.currentUser?.id.lowercased()
    }

    private func isMine(_ comment: ActivityComment) -> Bool {
        comment.userId.uuidString.lowercased() == currentUserId
    }

    /// Il proprio commento sempre; qualunque commento se la card è mia (moderazione di casa
    /// propria — la parola finale ce l'ha comunque il server).
    private func canDelete(_ comment: ActivityComment) -> Bool {
        isMine(comment) || activityOwnerId.uuidString.lowercased() == currentUserId
    }

    // MARK: - Azioni

    private func loadInitial() async {
        isLoading = true
        errorMessage = nil
        do {
            let page = try await ActivityInteractionService.shared.comments(
                activityId: activityId, after: nil, limit: pageSize)
            comments = page
            hasMore = page.count >= pageSize
        } catch {
            errorMessage = ActivityInteractionService.isContentUnavailable(error)
                ? "social.comments.unavailable".localized
                : error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        // Il cursore è l'ultima riga arrivata dal SERVER: i pendenti locali appesi in coda
        // non hanno un posto nel keyset remoto.
        guard let last = comments.last(where: { !$0.isPending }) else { return }
        isLoadingMore = true
        do {
            let next = try await ActivityInteractionService.shared.comments(
                activityId: activityId, after: (last.createdAt, last.id), limit: pageSize)
            let existing = Set(comments.map(\.id))
            comments.append(contentsOf: next.filter { !existing.contains($0.id) })
            hasMore = next.count >= pageSize
        } catch {
            // Pagina successiva fallita: silenzioso, il bottone resta e si ripreme.
            Logger.warning("[ActivityComments] Load more failed: \(error.localizedDescription)")
        }
        isLoadingMore = false
    }

    private func post() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isPosting = true

        // Un livello solo: rispondere a una reply aggancia il commento al SUO top-level.
        let parentId = replyingTo.map { $0.parentId ?? $0.id }

        do {
            let comment = try await ActivityInteractionService.shared.addComment(
                activityId: activityId, content: text, parentId: parentId)
            AnalyticsService.shared.track(.activityCommentAdded(
                activityType: analyticsActivityType ?? "unknown"))
            withAnimation(.easeOut(duration: 0.2)) {
                insertPosted(comment)
            }
            countDelta += 1
            onCommentCountChanged?(max(0, initialCommentCount + countDelta))
            composerText = ""
            replyingTo = nil
            composerFocused = false
            if comment.isPending {
                ToastCenter.shared.show(success: "social.comments.queuedOffline".localized)
            }
        } catch {
            ToastCenter.shared.show(error: ActivityInteractionService.isContentUnavailable(error)
                ? "social.comments.unavailable".localized
                : "social.comments.postFailed".localized)
        }
        isPosting = false
    }

    /// Una reply si infila dopo l'ultima sorella (o dopo il padre); un top-level in coda.
    private func insertPosted(_ comment: ActivityComment) {
        if let parentId = comment.parentId {
            let lastRelated = comments.lastIndex { $0.id == parentId || $0.parentId == parentId }
            if let index = lastRelated {
                comments.insert(comment, at: index + 1)
                return
            }
        }
        comments.append(comment)
    }

    private func delete(_ comment: ActivityComment) async {
        do {
            try await ActivityInteractionService.shared.deleteComment(commentId: comment.id)
        } catch {
            ToastCenter.shared.show(error: "social.comments.deleteFailed".localized)
            return
        }

        withAnimation(.easeOut(duration: 0.2)) {
            let hasLiveReplies = comments.contains { $0.parentId == comment.id && !$0.isDeleted }
            if hasLiveReplies {
                // La lapide: il filo delle risposte non si orfana, come sul server.
                if let index = comments.firstIndex(where: { $0.id == comment.id }) {
                    comments[index] = ActivityComment(
                        id: comment.id, activityId: comment.activityId, userId: comment.userId,
                        username: comment.username, displayName: comment.displayName,
                        avatarUrl: comment.avatarUrl, parentId: comment.parentId,
                        content: nil, isDeleted: true, createdAt: comment.createdAt,
                        likeCount: 0, likedByMe: false, isPending: false)
                }
            } else {
                comments.removeAll { $0.id == comment.id }
            }
        }
        countDelta -= 1
        onCommentCountChanged?(max(0, initialCommentCount + countDelta))
    }

    private func toggleLike(_ comment: ActivityComment) async {
        guard let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        let original = comments[index]

        // Ottimismo in pagina; il servizio fa il suo sullo specchio.
        var optimistic = original
        optimistic.likedByMe = !original.likedByMe
        optimistic.likeCount = max(0, original.likeCount + (original.likedByMe ? -1 : 1))
        withAnimation(.easeInOut(duration: 0.15)) { comments[index] = optimistic }

        do {
            let result = try await ActivityInteractionService.shared.toggleCommentLike(
                commentId: comment.id)
            if let idx = comments.firstIndex(where: { $0.id == comment.id }) {
                comments[idx].likedByMe = result.liked
                comments[idx].likeCount = result.likeCount
            }
        } catch {
            // Il rollback, mai un retry cieco: un toggle ritentato si inverte da solo.
            if let idx = comments.firstIndex(where: { $0.id == comment.id }) {
                withAnimation(.easeInOut(duration: 0.15)) { comments[idx] = original }
            }
            ToastCenter.shared.show(error: "social.error.likeFailed".localized)
        }
    }

    private func report(_ comment: ActivityComment) async {
        do {
            try await ActivityInteractionService.shared.report(
                type: .activityComment, contentId: comment.id)
            ToastCenter.shared.show(success: "social.report.done".localized)
        } catch {
            ToastCenter.shared.show(error: "social.report.failed".localized)
        }
    }
}

// MARK: - Riga

/// Stessa anatomia di `CommentRowView` dei clip (avatar 32, nome • tempo, testo, azioni),
/// sui colori del feed. Le lapidi si disegnano in corsivo, senza azioni.
private struct ActivityCommentThreadRow: View {
    let comment: ActivityComment
    let isReply: Bool
    let onLike: () -> Void
    let onReply: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isReply {
                // Il segno del rientro: la reply appartiene al filo qui sopra.
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 2)
                    .padding(.leading, 30)
            }

            avatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.displayName ?? comment.username ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                        .lineLimit(1)

                    Text("•")
                        .font(.system(size: 11))
                        .foregroundColor(.theme.textSecondary)

                    Text(Self.relativeTimeFormatter.localizedString(
                        for: comment.createdAt, relativeTo: Date()))
                        .font(.system(size: 11))
                        .foregroundColor(.theme.textSecondary)

                    if comment.isPending {
                        // Composto offline, in coda di replay: si dice, non si finge.
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundColor(.theme.textSecondary)
                    }

                    Spacer(minLength: 0)
                }

                if comment.isDeleted {
                    Text("social.comments.deleted".localized)
                        .font(.system(size: 13))
                        .italic()
                        .foregroundColor(.theme.textSecondary)
                } else {
                    Text(comment.content ?? "")
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 18) {
                        Button(action: handleLike) {
                            HStack(spacing: 4) {
                                Image(systemName: comment.likedByMe ? "heart.fill" : "heart")
                                    .font(.system(size: 12))
                                    .foregroundColor(comment.likedByMe
                                                     ? .theme.accentOrange : .theme.textSecondary)
                                if comment.likeCount > 0 {
                                    Text("\(comment.likeCount)")
                                        .font(.system(size: 11))
                                        .foregroundColor(.theme.textSecondary)
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel(Text("social.card.like".localized))

                        Button(action: onReply) {
                            Text("social.comments.reply".localized)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.theme.textSecondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatar: some View {
        if let avatarUrl = comment.avatarUrl, let url = URL(string: avatarUrl) {
            CachedAsyncImage(url: url, maxPixelSize: 100) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                avatarPlaceholder
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
        } else {
            avatarPlaceholder
                .frame(width: 32, height: 32)
                .clipShape(Circle())
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Circle().fill(Color.theme.accentOrange.opacity(0.25))
            Text(String((comment.displayName ?? comment.username ?? "?").prefix(1)).uppercased())
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.theme.accentOrange)
        }
    }

    private func handleLike() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        onLike()
    }

    private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

// MARK: - Previews

#Preview("Filo con reply e lapide") {
    let activityId = UUID()
    let parentId = UUID()
    let tombstoneId = UUID()
    return ActivityCommentsSheet(
        activityId: activityId,
        activityOwnerId: UUID(),
        initialCommentCount: 4,
        previewComments: [
            ActivityComment(
                id: parentId, activityId: activityId, userId: UUID(),
                username: "marta", displayName: "Marta", avatarUrl: nil, parentId: nil,
                content: "Che finale! Non me lo aspettavo per niente.",
                isDeleted: false, createdAt: Date().addingTimeInterval(-7200),
                likeCount: 3, likedByMe: true, isPending: false),
            ActivityComment(
                id: UUID(), activityId: activityId, userId: UUID(),
                username: "nicola", displayName: "Nicola", avatarUrl: nil, parentId: parentId,
                content: "Idem, il colpo di scena del terzo atto è da manuale.",
                isDeleted: false, createdAt: Date().addingTimeInterval(-3600),
                likeCount: 0, likedByMe: false, isPending: false),
            ActivityComment(
                id: tombstoneId, activityId: activityId, userId: UUID(),
                username: "gio", displayName: "Giorgia", avatarUrl: nil, parentId: nil,
                content: nil, isDeleted: true,
                createdAt: Date().addingTimeInterval(-1800),
                likeCount: 0, likedByMe: false, isPending: false),
            ActivityComment(
                id: UUID(), activityId: activityId, userId: UUID(),
                username: "luca", displayName: "Luca", avatarUrl: nil, parentId: tombstoneId,
                content: "Rispondo a un commento che non c'è più.",
                isDeleted: false, createdAt: Date().addingTimeInterval(-600),
                likeCount: 1, likedByMe: false, isPending: false),
            ActivityComment(
                id: UUID(), activityId: activityId, userId: UUID(),
                username: "me", displayName: "Io", avatarUrl: nil, parentId: nil,
                content: "Scritto offline, in coda di replay.",
                isDeleted: false, createdAt: Date().addingTimeInterval(-60),
                likeCount: 0, likedByMe: false, isPending: true)
        ])
}

#Preview("Vuoto") {
    ActivityCommentsSheet(
        activityId: UUID(),
        activityOwnerId: UUID(),
        initialCommentCount: 0,
        previewComments: [])
}
