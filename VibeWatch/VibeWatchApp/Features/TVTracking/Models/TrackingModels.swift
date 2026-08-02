import Foundation

/// SPEC v3 §3.4 — i bucket della schermata Tracking, calcolati dal **server**.
///
/// Il valore arriva da `tv_tracking_bucket()` in Postgres: qui non si decide niente, si legge.
/// È il punto di §1.1 — se il client sapesse ricavare il bucket, quella regola vivrebbe in due
/// posti e divergerebbero, che è esattamente ciò che sta per succedere con la web app in arrivo.
enum TrackingBucket: String, CaseIterable {
    case upNext = "up_next"
    case stale
    case forLater = "for_later"
    case upToDate = "up_to_date"
    case notStarted = "not_started"
    case dropped
    case archived

    /// L'ordine con cui le sezioni compaiono nella schermata (§9.2).
    static let displayOrder: [TrackingBucket] = [
        .upNext, .stale, .forLater, .upToDate, .notStarted,
    ]

    /// Sezioni chiuse di default: sono elenchi lunghi che non servono ogni giorno (§9.2).
    var isCollapsedByDefault: Bool {
        switch self {
        case .upNext: return false
        case .stale, .upToDate, .notStarted, .forLater, .dropped, .archived: return true
        }
    }

    var titleKey: String {
        switch self {
        case .upNext: return "tracking.bucket.upNext"
        case .stale: return "tracking.bucket.stale"
        case .forLater: return "tracking.bucket.forLater"
        case .upToDate: return "tracking.bucket.upToDate"
        case .notStarted: return "tracking.bucket.notStarted"
        case .dropped: return "tracking.bucket.dropped"
        case .archived: return "tracking.bucket.archived"
        }
    }
}

/// Una riga di `v_tv_tracking`: tutto ciò che serve a disegnare una card, senza rete.
///
/// Non ha metodi che calcolano progresso o prossimo episodio. Non è una dimenticanza: la versione
/// precedente di questa schermata li derivava dentro la View (`TVTrackingCard`, 60 righe di
/// computed properties più una chiamata TMDB per card), ed è la cosa che §1.1 dice di **eliminare**
/// invece di spostare in un ViewModel.
struct TrackingRow: Identifiable, Equatable {
    let showId: Int
    let userStatus: String
    let bucket: TrackingBucket

    let watchedCount: Int
    let airedCount: Int
    let totalCount: Int

    let nextSeason: Int?
    let nextEpisode: Int?
    let nextEpisodeName: String?
    let nextAirDate: Date?
    /// Il prossimo episodio è già uscito? Lo decide il server, che conosce il fuso dell'utente.
    let isNextAvailable: Bool

    let backlogSince: Date?
    let lastWatchedAt: Date?

    let showName: String?
    let posterPath: String?
    let nextStillPath: String?

    var id: Int { showId }

    /// `0...1`, già pronto per la barra. Il denominatore è ciò che è **uscito**, non il totale:
    /// una serie in corso con 3 episodi su 3 usciti è al 100%, non al 30% di una stagione che non
    /// esiste ancora.
    var progress: Double {
        guard airedCount > 0 else { return 0 }
        return min(1, Double(watchedCount) / Double(airedCount))
    }

    /// `S1E4`, o `nil` quando non c'è un prossimo episodio (utente in pari).
    var nextLabel: String? {
        guard let season = nextSeason, let episode = nextEpisode else { return nil }
        return "S\(season)E\(episode)"
    }
}

/// Una riga di `v_tv_timeline`: un'uscita dei prossimi 30 giorni.
struct TimelineEntry: Identifiable, Equatable {
    let id: String
    let showId: Int
    let showName: String?
    let posterPath: String?
    let seasonNumber: Int
    let episodeNumber: Int
    let episodeName: String?
    let airDate: Date
    let stillPath: String?
    /// §1.3: uno speciale si marca, non si filtra. Che farne è una scelta della UI.
    let isSpecial: Bool

    var label: String { "S\(seasonNumber)E\(episodeNumber)" }
}

/// Il raggruppamento della timeline in §9.2: Domani / Questa settimana / Questo mese.
enum TimelineGroup: String, CaseIterable {
    case today
    case tomorrow
    case thisWeek
    case thisMonth

    var titleKey: String {
        switch self {
        case .today: return "tracking.timeline.today"
        case .tomorrow: return "tracking.timeline.tomorrow"
        case .thisWeek: return "tracking.timeline.thisWeek"
        case .thisMonth: return "tracking.timeline.thisMonth"
        }
    }

    /// In quale gruppo cade una data, rispetto a `reference` (di norma oggi).
    ///
    /// Si conta in **giorni di calendario** e non in intervalli di 24 ore: un episodio che esce
    /// stasera alle 23 e uno che esce domani all'una sono "oggi" e "domani" per chi guarda, anche
    /// se li separano due ore.
    static func of(_ date: Date, reference: Date = Date(), calendar: Calendar = .current) -> TimelineGroup {
        let from = calendar.startOfDay(for: reference)
        let to = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: from, to: to).day ?? 0

        switch days {
        case ..<1: return .today          // include il passato: un'uscita di ieri non ha una sua sezione
        case 1: return .tomorrow
        case 2...7: return .thisWeek
        default: return .thisMonth
        }
    }
}

/// Ciò che la schermata riceve: sezioni già ordinate, già raggruppate, pronte da disegnare.
struct TrackingSections: Equatable {
    /// In ordine di `TrackingBucket.displayOrder`, senza i bucket vuoti.
    var sections: [(bucket: TrackingBucket, rows: [TrackingRow])] = []
    var timeline: [(group: TimelineGroup, entries: [TimelineEntry])] = []

    var isEmpty: Bool { sections.isEmpty && timeline.isEmpty }

    static func == (lhs: TrackingSections, rhs: TrackingSections) -> Bool {
        lhs.sections.map(\.bucket) == rhs.sections.map(\.bucket)
            && lhs.sections.map(\.rows) == rhs.sections.map(\.rows)
            && lhs.timeline.map(\.group) == rhs.timeline.map(\.group)
            && lhs.timeline.map(\.entries) == rhs.timeline.map(\.entries)
    }
}
