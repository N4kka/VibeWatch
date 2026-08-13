import SwiftUI

/// SPEC v3 §3.6/§9.3 — il voto in stelle su un film o una serie.
///
/// Il valore è un **intero 1-10** (mezze stelle, scala Letterboxd), identico al CHECK del server:
/// mai un float. Coesiste con il cuore: stelle = giudizio, cuore = "mi rappresenta".
///
/// Le tre regole imparate a caro prezzo, applicate qui:
/// - lo stato in volo si vede e blocca i tap: fra il tocco e la conferma c'è un giro di rete, e
///   un controllo muto invita a ripremere;
/// - un errore di scrittura si dichiara (`rating.saveFailed`) e lo stato torna quello vero — il
///   voto non resta sullo schermo se il server non l'ha mai saputo;
/// - la lettura iniziale viene dallo specchio locale (season/episode = -1: il sentinello dello
///   specchio, vedi migration SQLite 11), quindi zero rete per disegnarsi.
@MainActor
final class StarRatingViewModel: ObservableObject {
    @Published private(set) var rating: Int = 0       // 0 = nessun voto
    @Published private(set) var isSaving = false
    @Published private(set) var saveFailed = false

    /// Leggibili dalla View: la riga review e la card condivisa hanno bisogno della stessa
    /// identità del titolo, e duplicarla nella View sarebbe la copia che diverge.
    let mediaType: String
    let tmdbId: Int
    private let actions: RatingActions
    private let sqlite: SQLiteService
    private let currentUserId: @MainActor () -> String?

    init(mediaType: String, tmdbId: Int,
         actions: RatingActions = .shared,
         sqlite: SQLiteService = .shared,
         currentUserId: @escaping @MainActor () -> String? = { SupabaseService.shared.currentUser?.id }) {
        self.mediaType = mediaType
        self.tmdbId = tmdbId
        self.actions = actions
        self.sqlite = sqlite
        self.currentUserId = currentUserId
    }

    func load() async {
        guard let userId = currentUserId() else { return }
        do {
            let rows = try await sqlite.queryRaw(
                """
                SELECT rating FROM user_ratings
                WHERE user_id = ? AND media_type = ? AND tmdb_id = ?
                  AND season_number = -1 AND episode_number = -1
                  AND deleted_at IS NULL
                LIMIT 1
                """,
                parameters: [userId, mediaType, tmdbId])
            rating = (rows.first?["rating"] as? Int64).map(Int.init)
                ?? rows.first?["rating"] as? Int ?? 0
        } catch {
            // Nessun voto e "lettura fallita" qui coincidono di proposito: il controllo parte
            // vuoto e il primo tap scrive comunque. Non c'è un errore da travestire, perché
            // non si mostra nessun dato altrui.
            rating = 0
        }
    }

    /// Toccare il valore già impostato toglie il voto (come Letterboxd).
    func setRating(_ value: Int) async {
        guard !isSaving, (1...10).contains(value) else { return }
        let previous = rating
        let removing = (value == previous)

        isSaving = true
        saveFailed = false
        rating = removing ? 0 : value
        defer { isSaving = false }

        do {
            if removing {
                try await actions.removeRating(mediaType: mediaType, tmdbId: tmdbId)
            } else {
                try await actions.rate(mediaType: mediaType, tmdbId: tmdbId, rating: value)
            }
        } catch {
            // Lo stato torna quello vero: un voto che il server non ha mai saputo non resta
            // sullo schermo a mentire.
            rating = previous
            saveFailed = true
        }
    }
}

/// Cinque stelle a mezzi passi, a tocco **e a trascinamento**.
///
/// Il tocco secco resta quello di prima; il trascinamento sposta il voto in tempo reale con una
/// capsula flottante sopra il dito, perché senza un riscontro numerico "tre stelle e mezza" e
/// "quattro" si scelgono a caso. Un `DragGesture(minimumDistance: 0)` copre entrambi i casi: un
/// tap è un trascinamento lungo zero.
struct StarRatingSection: View {
    @StateObject private var viewModel: StarRatingViewModel

    @State private var previewRating: Int?
    @State private var starsWidth: CGFloat = 0
    @State private var dragX: CGFloat = 0

    /// La review viva del titolo (specchio locale). Solo movie/tv: per gli altri media type
    /// l'affordance non esiste, come la tabella remota vuole.
    @State private var review: ReviewActions.LocalReview?
    @State private var showComposer = false
    /// Item-based: la card nasce già con poster e firma risolti, mai un foglio mezzo vuoto.
    @State private var shareItem: RatedTitleShareItem?
    @State private var isPreparingShare = false

    private let haptics = UISelectionFeedbackGenerator()

    /// Quando è incorporata nella card condivisa con i preferiti, lo sfondo lo mette il
    /// contenitore: due sfondi sovrapposti disegnerebbero un bordo dove non c'è.
    private let isEmbedded: Bool

    /// Identità del titolo per la card condivisibile: senza titolo la card non si compone e
    /// l'affordance di share non compare. I chiamanti storici non passano niente e la sezione
    /// resta identica a prima.
    private let title: String?
    private let posterPath: String?

    init(mediaType: String, tmdbId: Int, isEmbedded: Bool = false,
         title: String? = nil, posterPath: String? = nil) {
        _viewModel = StateObject(wrappedValue: StarRatingViewModel(mediaType: mediaType, tmdbId: tmdbId))
        self.isEmbedded = isEmbedded
        self.title = title
        self.posterPath = posterPath
    }

    init(viewModel: StarRatingViewModel, isEmbedded: Bool = false,
         title: String? = nil, posterPath: String? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.isEmbedded = isEmbedded
        self.title = title
        self.posterPath = posterPath
    }

    /// Le review sono un fatto di film e serie interi ('movie'|'tv', come il CHECK remoto):
    /// per qualsiasi altro media type la riga sotto le stelle non deve nemmeno esistere.
    private var supportsReview: Bool {
        ["movie", "tv"].contains(viewModel.mediaType)
    }

    /// Da `x` sulla riga delle stelle al voto 1-10. Pura, così si può verificare senza toccare
    /// l'interfaccia: mezza stella ogni decimo di larghezza, i bordi non sfuggono dalla scala.
    static func ratingForDrag(x: CGFloat, totalWidth: CGFloat) -> Int {
        guard totalWidth > 0 else { return 1 }
        let step = totalWidth / 10
        let raw = Int((x / step).rounded(.up))
        return min(10, max(1, raw))
    }

    /// Il valore mostrato nella capsula: 7 → "3.5", 10 → "5".
    static func displayValue(for rating: Int) -> String {
        let value = Double(rating) / 2
        return value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    private var shownRating: Int {
        previewRating ?? viewModel.rating
    }

    var body: some View {
        Group {
            if isEmbedded {
                content
            } else {
                // Sfondo arrotondato senza ritaglio: la capsula del voto sporge sopra la
                // sezione mentre si trascina e un `clipShape` la taglierebbe a metà.
                content
                    .background(
                        RoundedRectangle(cornerRadius: 17)
                            .fill(Color.white.opacity(0.065))
                    )
            }
        }
        .task {
            await viewModel.load()
            await loadReview()
        }
        .sheet(isPresented: $showComposer) {
            ReviewComposerView(
                mediaType: viewModel.mediaType,
                tmdbId: viewModel.tmdbId,
                existingReview: review,
                onSaved: { Task { await loadReview() } },
                onDeleted: { review = nil }
            )
        }
        .sheet(item: $shareItem) { item in
            ShareCardSheet(content: item.content, link: item.link, onClose: { shareItem = nil })
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("rating.title".localized)
                    .font(.system(size: 15.5, weight: .heavy))
                    .foregroundColor(.theme.textPrimary)
                Spacer()
                starsRow
                    .opacity(viewModel.isSaving ? 0.5 : 1)
            }

            if viewModel.saveFailed {
                Text("rating.saveFailed".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }

            // La riga review+share compare solo A VALLE del voto: le stelle restano il
            // protagonista della sezione, e senza voto la card non avrebbe niente da dire.
            if supportsReview && viewModel.rating > 0 {
                reviewShareRow
            }
        }
        .padding(.horizontal, 17)
        // Con la sola riga del titolo il totale resta sotto `minHeight` e il layout storico
        // non si muove; quando c'è la riga review il padding evita che tocchi il bordo.
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 66)
    }

    // MARK: - Review e condivisione (social feed M1)

    private var reviewShareRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider().overlay(Color.white.opacity(0.08))

            HStack(alignment: .center, spacing: 10) {
                Button {
                    showComposer = true
                } label: {
                    if let review {
                        // Anteprima su due righe, in corsivo come sulla card: il tap riapre
                        // il composer precompilato.
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.theme.textSecondary)
                            Text("\u{201C}\(review.content)\u{201D}")
                                .font(.system(size: 13))
                                .italic()
                                .foregroundColor(.theme.textSecondary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                        }
                    } else {
                        HStack(spacing: 7) {
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .semibold))
                            Text("review.add".localized)
                                .font(.system(size: 13.5, weight: .semibold))
                        }
                        .foregroundColor(.theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text((review == nil
                                          ? "review.composer.title"
                                          : "review.composer.editTitle").localized))

                Spacer(minLength: 8)

                if title != nil {
                    shareButton
                }
            }
        }
        .padding(.top, 3)
    }

    private var shareButton: some View {
        Button {
            prepareShare()
        } label: {
            Group {
                if isPreparingShare {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(.theme.textSecondary)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.theme.textSecondary)
                }
            }
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .disabled(isPreparingShare)
        .accessibilityLabel(Text("shareCard.share".localized))
    }

    private func loadReview() async {
        guard supportsReview else { return }
        review = await ReviewActions.shared.review(for: viewModel.mediaType, tmdbId: viewModel.tmdbId)
    }

    /// La card si prepara prima di presentare il foglio: poster e firma arrivano in async e
    /// un foglio aperto "a metà" mostrerebbe il placeholder per poi cambiare faccia.
    private func prepareShare() {
        guard let title, !isPreparingShare, viewModel.rating > 0 else { return }
        isPreparingShare = true
        Task {
            let poster = await ShareCardRenderer.posterImage(path: posterPath)
            let identity = await ShareCardIdentity.current()
            // Una review segnata spoiler non finisce su una card pubblica: la card resta
            // voto+poster, che non rovinano niente a nessuno.
            let quote = (review?.containsSpoilers == false) ? review?.content : nil
            shareItem = RatedTitleShareItem(
                content: .ratedTitle(.init(
                    title: title,
                    rating: viewModel.rating,
                    review: quote,
                    username: identity.handle,
                    profileLink: identity.drawnLink,
                    poster: poster
                )),
                link: identity.profileURL)
            isPreparingShare = false
        }
    }

    private var starsRow: some View {
        HStack(spacing: 7) {
            ForEach(1...5, id: \.self) { star in starView(star) }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { starsWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in starsWidth = width }
            }
        )
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .overlay(alignment: .topLeading) { floatingValue }
        // Il trascinamento toglierebbe il controllo a VoiceOver: qui il voto si regola a passi.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("rating.title".localized))
        .accessibilityValue(Text(Self.displayValue(for: viewModel.rating)))
        .accessibilityAdjustableAction { direction in
            let next: Int
            switch direction {
            case .increment: next = min(10, viewModel.rating + 1)
            case .decrement: next = max(1, viewModel.rating - 1)
            @unknown default: return
            }
            guard next != viewModel.rating else { return }
            Task { await viewModel.setRating(next) }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragX = value.location.x
                let next = Self.ratingForDrag(x: value.location.x, totalWidth: starsWidth)
                guard next != previewRating else { return }
                previewRating = next
                haptics.selectionChanged()
            }
            .onEnded { _ in
                guard let value = previewRating else { return }
                Task {
                    // Stesso `setRating` del tap: ripassare sul valore già impostato lo toglie.
                    await viewModel.setRating(value)
                    previewRating = nil
                }
            }
    }

    @ViewBuilder
    private var floatingValue: some View {
        if let previewRating {
            Text(Self.displayValue(for: previewRating))
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.theme.background.opacity(0.96)))
                .overlay(Capsule().stroke(Color.theme.accentOrange, lineWidth: 1))
                .fixedSize()
                .offset(x: min(max(dragX - 20, -8), max(starsWidth - 32, 0)), y: -34)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// Wrapper Identifiable per `.sheet(item:)`: il contenuto della card da solo non basta.
    fileprivate struct RatedTitleShareItem: Identifiable {
        let id = UUID()
        let content: ShareCardContent
        /// L'indirizzo del profilo che accompagna la card nella share sheet.
        let link: URL?
    }

    private func starView(_ star: Int) -> some View {
        // Valore 1-10: la stella i è piena da 2i, mezza a 2i-1.
        let symbol: String
        if shownRating >= star * 2 {
            symbol = "star.fill"
        } else if shownRating == star * 2 - 1 {
            symbol = "star.leadinghalf.filled"
        } else {
            symbol = "star"
        }

        return Image(systemName: symbol)
            .font(.system(size: 23))
            .foregroundColor(.theme.accentOrange)
    }
}
