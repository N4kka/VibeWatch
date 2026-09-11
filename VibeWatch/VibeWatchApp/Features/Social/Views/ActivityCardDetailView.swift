import SwiftUI

/// Social feed M3 — dove atterra il tap su una push "ti hanno messo like / hanno commentato":
/// la card di cui parla la notifica, da sola, con like e commenti vivi.
///
/// Non è una pagina del feed con un filtro: è una lettura per id (`get_activity_feed` con
/// `p_activity_id`), stessi cancelli e nessuna scorciatoia. Tre esiti e tutti dichiarati —
/// carico, non più disponibile (bloccato, tolto dal feed, profilo tornato privato), errore di
/// rete con la riprova. Un "non disponibile" travestito da errore, o viceversa, manderebbe
/// l'utente a ricaricare qualcosa che non tornerà.
struct ActivityCardDetailView: View {
    let activityId: UUID
    var onClose: () -> Void

    @State private var phase: Phase = .loading
    @State private var showComments = false
    @State private var detailTarget: ActivityCardDetailTarget?
    @State private var profileTarget: ActivityCardProfileTarget?

    private let repository: ActivityFeedProviding
    private let currentUserId: @MainActor () -> String?

    init(activityId: UUID,
         onClose: @escaping () -> Void,
         repository: ActivityFeedProviding? = nil,
         currentUserId: @escaping @MainActor () -> String? = { SupabaseService.shared.currentUser?.id }) {
        self.activityId = activityId
        self.onClose = onClose
        self.repository = repository ?? ActivityFeedRepository()
        self.currentUserId = currentUserId
    }

    private enum Phase {
        case loading
        case loaded(ActivityItem)
        case unavailable
        case failed
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("social.activity.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityLabel(Text("common.close".localized))
                }
            }
            .navigationDestination(item: $detailTarget) { target in
                if target.mediaType == "movie" {
                    MovieDetailView(movieId: target.tmdbId)
                } else {
                    TVShowDetailView(tvShowId: target.tmdbId)
                }
            }
            .sheet(item: $profileTarget) { target in
                NavigationStack {
                    PublicProfileView(username: target.username)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button { profileTarget = nil } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .accessibilityLabel(Text("common.close".localized))
                            }
                        }
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .unavailable:
            message(icon: "eye.slash", textKey: "social.activity.unavailable", retry: false)
        case .failed:
            message(icon: "wifi.exclamationmark", textKey: "social.activity.loadFailed", retry: true)
        case .loaded(let item):
            ScrollView {
                VStack(spacing: 16) {
                    ActivityCardView(
                        item: item,
                        isOwnCard: isOwnCard(item),
                        onOpenProfile: { username in
                            profileTarget = ActivityCardProfileTarget(username: username)
                        },
                        onOpenDetail: {
                            guard let tmdbId = item.tmdbId, let mediaType = item.mediaType else { return }
                            detailTarget = ActivityCardDetailTarget(mediaType: mediaType, tmdbId: tmdbId)
                        })
                    // La notifica parlava di un commento: il foglio è a un tap, non a una
                    // caccia al tesoro dentro la fila delle azioni.
                    Button { showComments = true } label: {
                        Text("social.activity.openComments".localized)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.theme.accentOrange)
                    }
                }
                .padding(20)
            }
            .sheet(isPresented: $showComments) {
                ActivityCommentsSheet(
                    activityId: item.id,
                    activityOwnerId: item.userId,
                    initialCommentCount: item.commentCount,
                    onCommentCountChanged: { count in
                        // La card riflette subito il conteggio vero: la si è aperta per questo.
                        if case .loaded(let current) = phase {
                            phase = .loaded(current.updatingCommentCount(max(0, count)))
                        }
                    },
                    analyticsActivityType: item.activityType.rawValue)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func isOwnCard(_ item: ActivityItem) -> Bool {
        guard let uid = currentUserId() else { return false }
        return item.userId.uuidString.lowercased() == uid.lowercased()
    }

    private func load() async {
        phase = .loading
        do {
            guard let item = try await repository.fetchActivity(id: activityId) else {
                phase = .unavailable
                return
            }
            phase = .loaded(await ActivityMovieEnricher.enrich([item]).first ?? item)
        } catch {
            phase = .failed
        }
    }

    private func message(icon: String, textKey: String, retry: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(.theme.textSecondary.opacity(0.6))
            Text(textKey.localized)
                .font(.system(size: 15))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
            if retry {
                Button("common.retry".localized) {
                    Task { await load() }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.theme.accentOrange)
            }
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Target di presentazione

private struct ActivityCardDetailTarget: Identifiable, Hashable {
    let mediaType: String
    let tmdbId: Int
    var id: String { "\(mediaType)-\(tmdbId)" }
}

private struct ActivityCardProfileTarget: Identifiable {
    let username: String
    var id: String { username }
}

private extension ActivityItem {
    /// Solo il conteggio commenti: è l'unico campo che questa schermata vede cambiare, e
    /// ricostruire la riga intera per il resto sarebbe inventare dati che non ha riletto.
    func updatingCommentCount(_ newCount: Int) -> ActivityItem {
        ActivityItem(
            id: id, userId: userId, username: username, displayName: displayName,
            avatarUrl: avatarUrl, activityType: activityType, mediaType: mediaType,
            tmdbId: tmdbId, episodeCount: episodeCount, rating: rating, reviewId: reviewId,
            reviewContent: reviewContent, containsSpoilers: containsSpoilers, listId: listId,
            listName: listName, listCoverPosterPaths: listCoverPosterPaths,
            title: title, posterPath: posterPath, occurredAt: occurredAt,
            likeCount: likeCount, commentCount: newCount, likedByMe: likedByMe)
    }
}
