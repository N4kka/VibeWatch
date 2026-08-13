import SwiftUI

/// Una card del feed attività: autore in testa, poster a sinistra, il fatto a destra.
/// Stessa famiglia visiva di `PublicListCard`/`TVTrackingCard` (poster 96x144, fondo 5%).
///
/// Le azioni escono per closure invece di navigare da sole: sheet e navigazione vivono nel
/// feed, così la card resta un puro disegno di una riga e le anteprime non trascinano mezzo
/// stack di presentazione.
struct ActivityCardView: View {
    let item: ActivityItem
    /// Card dell'utente in sessione: solo lì compare lo share; la moderazione dei commenti
    /// e il "segnala review" si decidono anche da qui.
    let isOwnCard: Bool
    var onOpenProfile: (String) -> Void
    var onOpenDetail: () -> Void
    var onShare: () -> Void
    /// M2 — il like esce per closure come le altre azioni: l'ottimismo, la riconciliazione e
    /// il rollback vivono nel ViewModel, la card disegna soltanto lo stato che le arriva.
    var onToggleLike: () -> Void = {}
    /// Il foglio commenti riporta fuori il conteggio aggiornato quando cambia: il feed
    /// aggiorna la riga senza rifare la pagina.
    var onCommentCountChanged: (Int) -> Void = { _ in }
    /// Conferma già raccolta (il dialog è della card): al chiamante resta solo la RPC.
    var onReportReview: () -> Void = {}

    /// Lo spoiler si rivela per card e per sessione: un flag persistente sarebbe memoria
    /// di troppo per un gesto che costa un tap.
    @State private var spoilerRevealed = false
    /// Il foglio commenti si presenta da qui: la card è l'unica a sapere di quale attività
    /// si parla, e il feed non deve trascinarsi un target in più.
    @State private var showComments = false
    @State private var showReportConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            authorRow

            HStack(alignment: .top, spacing: 14) {
                mediaThumbnail
                    .frame(width: 96, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 6) {
                    verbLine

                    if item.activityType == .rated, let rating = item.rating {
                        starRow(rating: rating)
                    }

                    if let review = item.reviewContent, !review.isEmpty {
                        reviewText(review)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Il tap sul contenuto apre il dettaglio del titolo; l'autore ha il suo tap sopra.
            .contentShape(Rectangle())
            .onTapGesture {
                guard item.tmdbId != nil else { return }
                onOpenDetail()
            }

            actionRow
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $showComments) {
            ActivityCommentsSheet(
                activityId: item.id,
                activityOwnerId: item.userId,
                initialCommentCount: item.commentCount,
                onCommentCountChanged: onCommentCountChanged)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "social.report.confirmTitle".localized,
            isPresented: $showReportConfirm,
            titleVisibility: .visible
        ) {
            Button("social.report.confirm".localized, role: .destructive) {
                onReportReview()
            }
            Button("common.cancel".localized, role: .cancel) {}
        }
    }

    // MARK: - Autore

    private var authorRow: some View {
        Button {
            if let username = item.username { onOpenProfile(username) }
        } label: {
            HStack(spacing: 10) {
                avatar

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayName ?? item.username ?? "")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                        .lineLimit(1)

                    if let username = item.username {
                        Text("@\(username)")
                            .font(.system(size: 12))
                            .foregroundColor(.theme.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Text(Self.relativeTimeFormatter.localizedString(for: item.occurredAt, relativeTo: Date()))
                    .font(.system(size: 12))
                    .foregroundColor(.theme.textSecondary)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private var avatar: some View {
        if let avatarUrl = item.avatarUrl, let url = URL(string: avatarUrl) {
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
            Text(String((item.displayName ?? item.username ?? "?").prefix(1)).uppercased())
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.theme.accentOrange)
        }
    }

    // MARK: - Poster / copertine

    @ViewBuilder
    private var mediaThumbnail: some View {
        if item.activityType == .listCreated {
            listCover
        } else {
            poster(item.posterPath)
        }
    }

    /// Stessa griglia 2x2 di PublicListCard: sotto 4 copertine si mostra la prima, senza
    /// copertine il ripiego con l'icona.
    @ViewBuilder
    private var listCover: some View {
        let paths = item.listCoverPosterPaths ?? []
        if paths.isEmpty {
            posterFallback(icon: "list.bullet")
        } else if paths.count < 4 {
            poster(paths[0])
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
                ForEach(Array(paths.prefix(4).enumerated()), id: \.offset) { _, path in
                    poster(path).frame(height: 71).clipped()
                }
            }
        }
    }

    @ViewBuilder
    private func poster(_ path: String?) -> some View {
        if let path, let url = URL(string: "https://image.tmdb.org/t/p/w342\(path)") {
            CachedAsyncImage(url: url, maxPixelSize: 400) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Color.theme.backgroundDark.opacity(0.5))
            }
        } else {
            posterFallback(icon: "film")
        }
    }

    private func posterFallback(icon: String) -> some View {
        Rectangle()
            .fill(Color.theme.backgroundDark.opacity(0.5))
            .overlay {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundColor(.theme.textSecondary)
            }
    }

    // MARK: - Verbo

    /// La frase del fatto, per tipo. Le stringhe localizzate portano il titolo in grassetto
    /// via markdown (`**%@**`): l'ordine delle parole resta della lingua, non del codice.
    @ViewBuilder
    private var verbLine: some View {
        switch item.activityType {
        case .watched:
            if item.mediaType == "tv", let count = item.episodeCount, count > 0 {
                if count == 1 {
                    markdownText(String(format: "social.card.watchedEpisode".localized, displayTitle))
                } else {
                    markdownText(String(format: "social.card.watchedEpisodes".localized, count, displayTitle))
                }
            } else {
                markdownText(String(format: "social.card.watchedMovie".localized, displayTitle))
            }
        case .rated:
            markdownText(String(format: "social.card.rated".localized, displayTitle))
        case .listCreated:
            markdownText(String(format: "social.card.createdList".localized,
                                item.listName ?? "social.card.unknownTitle".localized))
        case .showCompleted:
            // La card celebrativa: badge d'accento discreto sopra la frase.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10, weight: .heavy))
                    Text("social.card.completedBadge".localized.uppercased())
                        .font(.system(size: 10, weight: .heavy))
                        .kerning(1.1)
                }
                .foregroundColor(.theme.accentOrange)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.theme.accentOrange.opacity(0.16)))

                markdownText(String(format: "social.card.completed".localized, displayTitle))
            }
        }
    }

    private var displayTitle: String {
        item.title ?? "social.card.unknownTitle".localized
    }

    /// `AttributedString(markdown:)` per il grassetto del titolo; se il parsing fallisce
    /// (asterischi nel titolo, chissà) si mostra il testo piatto — mai una card vuota.
    private func markdownText(_ string: String) -> Text {
        if let attributed = try? AttributedString(markdown: string) {
            return Text(attributed)
                .font(.system(size: 15))
                .foregroundColor(.theme.textPrimary)
        }
        return Text(string)
            .font(.system(size: 15))
            .foregroundColor(.theme.textPrimary)
    }

    // MARK: - Stelle

    /// La stessa mappatura di StarRatingSection: voto 1-10 a mezze stelle, valore accanto
    /// perché cinque stelline da 13pt da sole non si leggono.
    private func starRow(rating: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: starSymbol(for: star, rating: rating))
                    .font(.system(size: 13))
                    .foregroundColor(.theme.accentOrange)
            }
            Text(StarRatingSection.displayValue(for: rating))
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .padding(.leading, 3)
        }
    }

    private func starSymbol(for star: Int, rating: Int) -> String {
        if rating >= star * 2 { return "star.fill" }
        if rating == star * 2 - 1 { return "star.leadinghalf.filled" }
        return "star"
    }

    // MARK: - Recensione

    @ViewBuilder
    private func reviewText(_ review: String) -> some View {
        let hasSpoilers = item.containsSpoilers == true
        Text("\u{201C}\(review)\u{201D}")
            .font(.system(size: 13))
            .italic()
            .foregroundColor(.theme.textSecondary)
            .lineLimit(4)
            .blur(radius: hasSpoilers && !spoilerRevealed ? 6 : 0)
            .overlay {
                if hasSpoilers && !spoilerRevealed {
                    // Il velo dichiara cosa nasconde e come si toglie: un blur muto sembra un bug.
                    HStack(spacing: 5) {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("social.card.spoiler".localized)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.theme.background.opacity(0.85)))
                }
            }
            .contentShape(Rectangle())
            // highPriority non serve: quando lo spoiler è coperto questo tap vince perché il
            // gesture più interno ha precedenza su quello della card.
            .onTapGesture {
                if hasSpoilers && !spoilerRevealed {
                    withAnimation(.easeOut(duration: 0.2)) { spoilerRevealed = true }
                } else if item.tmdbId != nil {
                    onOpenDetail()
                }
            }
            // Segnalabile solo la review ALTRUI: il proprio contenuto non si segnala (il
            // server risponderebbe con un no-op, ma il tasto non deve proprio esserci).
            .contextMenu {
                if !isOwnCard, item.reviewId != nil {
                    Button {
                        showReportConfirm = true
                    } label: {
                        Label("social.report.review".localized, systemImage: "flag")
                    }
                }
            }
    }

    // MARK: - Azioni (M2: like e commenti su tutte le card, share solo sulle proprie)

    private var shareableContentExists: Bool {
        switch item.activityType {
        case .rated: return item.rating != nil
        case .showCompleted: return true
        case .watched, .listCreated: return false
        }
    }

    /// La fila resta calma: icone piccole, contatori solo quando c'è qualcosa da contare.
    private var actionRow: some View {
        HStack(spacing: 20) {
            Button(action: handleLikeTap) {
                HStack(spacing: 5) {
                    Image(systemName: item.likedByMe ? "heart.fill" : "heart")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(item.likedByMe ? .theme.accentOrange : .theme.textSecondary)
                    if item.likeCount > 0 {
                        Text("\(item.likeCount)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.theme.textSecondary)
                            .contentTransition(.numericText())
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(Text("social.card.like".localized))

            Button {
                showComments = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.textSecondary)
                    if item.commentCount > 0 {
                        Text("\(item.commentCount)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.theme.textSecondary)
                            .contentTransition(.numericText())
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(Text("social.card.comments".localized))

            Spacer()

            if isOwnCard && shareableContentExists {
                Button(action: onShare) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                        Text("social.card.share".localized)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private func handleLikeTap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        onToggleLike()
    }

    /// Condiviso e statico: un formatter per card sarebbe un'allocazione per riga di feed.
    private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

// MARK: - Previews

#Preview("Rated con spoiler") {
    ZStack {
        Color.theme.background.ignoresSafeArea()
        ActivityCardView(
            item: ActivityItem(
                id: UUID(), userId: UUID(), username: "nicola", displayName: "Nicola",
                avatarUrl: nil, activityType: .rated, mediaType: "movie", tmdbId: 157336,
                episodeCount: nil, rating: 9, reviewId: UUID(),
                reviewContent: "Il finale ribalta tutto: il vero antagonista era il tempo.",
                containsSpoilers: true, listId: nil, listName: nil, listCoverPosterPaths: nil,
                title: "Interstellar", posterPath: nil,
                occurredAt: Date().addingTimeInterval(-3600),
                likeCount: 0, commentCount: 0, likedByMe: false),
            isOwnCard: true,
            onOpenProfile: { _ in }, onOpenDetail: {}, onShare: {})
        .padding(20)
    }
}

#Preview("Episodi e serie finita") {
    ZStack {
        Color.theme.background.ignoresSafeArea()
        VStack(spacing: 16) {
            ActivityCardView(
                item: ActivityItem(
                    id: UUID(), userId: UUID(), username: "marta", displayName: "Marta",
                    avatarUrl: nil, activityType: .watched, mediaType: "tv", tmdbId: 1396,
                    episodeCount: 5, rating: nil, reviewId: nil, reviewContent: nil,
                    containsSpoilers: nil, listId: nil, listName: nil, listCoverPosterPaths: nil,
                    title: "Breaking Bad", posterPath: nil,
                    occurredAt: Date().addingTimeInterval(-7200),
                    likeCount: 0, commentCount: 0, likedByMe: false),
                isOwnCard: false,
                onOpenProfile: { _ in }, onOpenDetail: {}, onShare: {})

            ActivityCardView(
                item: ActivityItem(
                    id: UUID(), userId: UUID(), username: "marta", displayName: "Marta",
                    avatarUrl: nil, activityType: .showCompleted, mediaType: "tv", tmdbId: 1396,
                    episodeCount: 62, rating: nil, reviewId: nil, reviewContent: nil,
                    containsSpoilers: nil, listId: nil, listName: nil, listCoverPosterPaths: nil,
                    title: "Breaking Bad", posterPath: nil,
                    occurredAt: Date().addingTimeInterval(-86400),
                    likeCount: 0, commentCount: 0, likedByMe: false),
                isOwnCard: false,
                onOpenProfile: { _ in }, onOpenDetail: {}, onShare: {})
        }
        .padding(20)
    }
}

#Preview("Lista creata") {
    ZStack {
        Color.theme.background.ignoresSafeArea()
        ActivityCardView(
            item: ActivityItem(
                id: UUID(), userId: UUID(), username: "gio", displayName: "Giorgia",
                avatarUrl: nil, activityType: .listCreated, mediaType: nil, tmdbId: nil,
                episodeCount: nil, rating: nil, reviewId: nil, reviewContent: nil,
                containsSpoilers: nil, listId: UUID(), listName: "Notti horror",
                listCoverPosterPaths: nil, title: nil, posterPath: nil,
                occurredAt: Date().addingTimeInterval(-172800),
                likeCount: 0, commentCount: 0, likedByMe: false),
            isOwnCard: false,
            onOpenProfile: { _ in }, onOpenDetail: {}, onShare: {})
        .padding(20)
    }
}
