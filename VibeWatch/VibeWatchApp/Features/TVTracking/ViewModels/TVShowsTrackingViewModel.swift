import Foundation
import Combine

@MainActor
final class TVShowsTrackingViewModel: ObservableObject {
    @Published private(set) var sections = TrackingSections()
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    /// Quali sezioni l'utente ha aperto. Il default lo decide `isCollapsedByDefault` (§9.2).
    @Published var expanded: Set<TrackingBucket> = Set(
        TrackingBucket.displayOrder.filter { !$0.isCollapsedByDefault }
    )

    private let repository: any TrackingRepositoryProtocol
    private let refreshTitles: (Set<Int>) async -> Bool
    private let refreshEpisodeNames: ([Int: Set<LocalizedTitleStore.EpisodeRef>]) async -> Bool
    private var cancellables = Set<AnyCancellable>()

    convenience init() {
        self.init(repository: LocalTrackingRepository.shared)
    }

    init(repository: any TrackingRepositoryProtocol,
         refreshTitles: @escaping (Set<Int>) async -> Bool = {
             await LocalizedTitleStore.shared.refreshMissing(mediaType: "tv", ids: $0)
         },
         refreshEpisodeNames: @escaping ([Int: Set<LocalizedTitleStore.EpisodeRef>]) async -> Bool = { byShow in
             var wrote = false
             for (showId, refs) in byShow {
                 if await LocalizedTitleStore.shared.refreshMissingEpisodeNames(showId: showId, refs: refs) {
                     wrote = true
                 }
             }
             return wrote
         }) {
        self.repository = repository
        self.refreshTitles = refreshTitles
        self.refreshEpisodeNames = refreshEpisodeNames

        // Si ricarica quando il sync ha portato righe nuove, non quando cambia una lista locale.
        // È la differenza con la versione precedente, che si agganciava a `ListManager` e a
        // `EpisodeSeenManager` perché da lì ricavava i bucket da sé: ora i bucket li calcola il
        // server (§1.1) e l'unico evento che conta è "è arrivata roba nuova".
        NotificationCenter.default.publisher(for: .syncEngineCompleted)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.load() } }
            .store(in: &cancellables)
    }

    /// - Parameter measuring: se `true`, cronometra il percorso per §13.6. Lo fa solo la prima
    ///   apertura della schermata: un `refreshable` o un ricarico dopo il sync non sono il caso
    ///   che il requisito descrive, e mescolarli falserebbe la misura verso il basso.
    func load(measuring: Bool = false) async {
        if measuring { TrackingPerformanceProbe.begin() }
        isLoading = true
        defer { isLoading = false }

        do {
            sections = try await repository.fetchSections()
            if measuring {
                TrackingPerformanceProbe.dataReady(
                    rows: sections.sections.reduce(0) { $0 + $1.rows.count })
            }
            lastError = nil

            // Il primo fotogramma è già a schermo, coi titoli del catalogo come ripiego: ora,
            // fuori dal budget di §13.6, si riempie la cache dei titoli nella lingua dell'app —
            // serie E nomi degli episodi (una chiamata per stagione, non per riga). Entrambi i
            // refresh scrivono solo i buchi e rispondono false quando non c'è niente di nuovo,
            // quindi il giro converge da solo: al secondo passaggio non rilancia.
            let ids = Set(sections.sections.flatMap { $0.rows.map(\.showId) }
                        + sections.timeline.flatMap { $0.entries.map(\.showId) })
            var episodeRefs: [Int: Set<LocalizedTitleStore.EpisodeRef>] = [:]
            for row in sections.sections.flatMap(\.rows) {
                if let s = row.nextSeason, let e = row.nextEpisode {
                    episodeRefs[row.showId, default: []].insert(.init(season: s, episode: e))
                }
            }
            for entry in sections.timeline.flatMap(\.entries) {
                episodeRefs[entry.showId, default: []]
                    .insert(.init(season: entry.seasonNumber, episode: entry.episodeNumber))
            }
            if !ids.isEmpty || !episodeRefs.isEmpty {
                Task { [weak self] in
                    guard let self else { return }
                    var wrote = await self.refreshTitles(ids)
                    if await self.refreshEpisodeNames(episodeRefs) { wrote = true }
                    if wrote { await self.load() }
                }
            }
        } catch {
            // Si dichiara e si logga. Un `try?` qui produrrebbe una schermata vuota
            // indistinguibile da "non segui niente" — ed è lo stesso fallimento silenzioso che in
            // questo progetto è già costato una giornata di diagnosi.
            lastError = error.localizedDescription
            Logger.error("[Tracking] lettura fallita: \(error.localizedDescription)")
        }
    }

    func isExpanded(_ bucket: TrackingBucket) -> Bool { expanded.contains(bucket) }

    func toggle(_ bucket: TrackingBucket) {
        if expanded.contains(bucket) { expanded.remove(bucket) } else { expanded.insert(bucket) }
    }
}
