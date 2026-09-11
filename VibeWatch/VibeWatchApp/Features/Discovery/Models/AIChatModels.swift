import Foundation

/// Card di raccomandazione risolta via TMDB a partire dal blocco vibe-json del modello.
struct AIRecommendationCardModel: Identifiable, Equatable {
    let tmdbId: Int
    let mediaType: MediaType
    let title: String
    let year: String?
    let posterPath: String?
    /// Confidence del modello clampata 55–97 (vedi AIResponseParser).
    let matchPercent: Int
    let reason: String
    /// "1h 52m" per i film, "3 stagioni" per le serie (già localizzato).
    let seasonsOrRuntime: String?
    let country: String?

    var id: Int { tmdbId }
}

/// Messaggio della chat Vibe AI. `content` resta il testo grezzo persistito (incluso l'eventuale
/// blocco vibe-json); `text` è la parte conversazionale da mostrare e `cards` le raccomandazioni
/// risolte. I messaggi utente hanno sempre `cards` vuote e `text == content`.
struct AIMessage: Identifiable, Equatable {
    let id = UUID()
    var content: String
    let isUser: Bool
    var isEditing: Bool = false
    var text: String
    var cards: [AIRecommendationCardModel]
    /// Feedback pollice su/giù dell'utente su questa risposta (solo UI/analytics, v1 locale).
    var feedback: Bool?

    init(content: String, isUser: Bool, text: String? = nil, cards: [AIRecommendationCardModel] = []) {
        self.content = content
        self.isUser = isUser
        self.text = text ?? content
        self.cards = cards
        self.feedback = nil
    }
}

extension AIRecommendationCardModel {
    /// Movie sintetico per ListManager.addToList (stesso pattern di MediaListItem.asMovie()).
    func asMovie() -> Movie {
        Movie(
            id: tmdbId,
            title: title,
            overview: "",
            posterPath: posterPath,
            backdropPath: nil,
            releaseDate: year.map { "\($0)-01-01" },
            voteAverage: 0.0,
            voteCount: 0,
            genreIds: nil,
            genres: nil,
            adult: false,
            originalLanguage: "",
            popularity: 0.0,
            runtime: nil,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: nil
        )
    }
}

/// Filtri della chat: vincoli passati al prompt (vedi AIContextBuilder.buildActiveFiltersSection).
enum AIChatFilter: Hashable {
    case myPlatforms([String])
    case recent
    case shorter
    case hiddenGems

    /// Label della chip; per myPlatforms il nome del primo provider ("Solo su Netflix").
    var chipLabel: String {
        switch self {
        case .myPlatforms(let names):
            if names.count == 1, let first = names.first {
                return String(format: "ai.filter.onlyOn".localized, first)
            }
            return "ai.filter.myPlatforms".localized
        case .recent: return "ai.filter.recent".localized
        case .shorter: return "ai.filter.shorter".localized
        case .hiddenGems: return "ai.filter.hiddenGems".localized
        }
    }

    /// Nome mostrato nella pill "Filtro applicato: X".
    var appliedName: String {
        switch self {
        case .myPlatforms(let names):
            return names.count == 1 ? (names.first ?? "") : "ai.filter.myPlatforms.short".localized
        case .recent: return "ai.filter.recent".localized
        case .shorter: return "ai.filter.shorter".localized
        case .hiddenGems: return "ai.filter.hiddenGems".localized
        }
    }
}
