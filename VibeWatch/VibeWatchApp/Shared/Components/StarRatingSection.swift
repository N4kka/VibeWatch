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

    private let mediaType: String
    private let tmdbId: Int
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

/// Cinque stelle a mezzi passi: il tocco sulla metà sinistra vale la mezza stella, sulla destra
/// la piena. Da usare nei dettagli film/serie sotto le azioni.
struct StarRatingSection: View {
    @StateObject private var viewModel: StarRatingViewModel

    init(mediaType: String, tmdbId: Int) {
        _viewModel = StateObject(wrappedValue: StarRatingViewModel(mediaType: mediaType, tmdbId: tmdbId))
    }

    init(viewModel: StarRatingViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("rating.title".localized)
                    .font(.system(size: 15.5, weight: .heavy))
                    .foregroundColor(.theme.textPrimary)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(1...5, id: \.self) { star in starView(star) }
                }
                .opacity(viewModel.isSaving ? 0.5 : 1)
            }

            if viewModel.saveFailed {
                Text("rating.saveFailed".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 66)
        .background(Color.white.opacity(0.065))
        .clipShape(RoundedRectangle(cornerRadius: 17))
        .task { await viewModel.load() }
    }

    private func starView(_ star: Int) -> some View {
        // Valore 1-10: la stella i è piena da 2i, mezza a 2i-1.
        let symbol: String
        if viewModel.rating >= star * 2 {
            symbol = "star.fill"
        } else if viewModel.rating == star * 2 - 1 {
            symbol = "star.leadinghalf.filled"
        } else {
            symbol = "star"
        }

        return Image(systemName: symbol)
            .font(.system(size: 23))
            .foregroundColor(.theme.accentOrange)
            .overlay(
                // Due zone di tocco invisibili: sinistra = mezza (2i-1), destra = piena (2i).
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { Task { await viewModel.setRating(star * 2 - 1) } }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { Task { await viewModel.setRating(star * 2) } }
                }
            )
            .accessibilityElement()
            .accessibilityLabel(Text("rating.title".localized))
            .accessibilityValue(Text("\(viewModel.rating)"))
    }
}
