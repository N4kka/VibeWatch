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
    private var cancellables = Set<AnyCancellable>()

    convenience init() {
        self.init(repository: LocalTrackingRepository.shared)
    }

    init(repository: any TrackingRepositoryProtocol) {
        self.repository = repository

        // Si ricarica quando il sync ha portato righe nuove, non quando cambia una lista locale.
        // È la differenza con la versione precedente, che si agganciava a `ListManager` e a
        // `EpisodeSeenManager` perché da lì ricavava i bucket da sé: ora i bucket li calcola il
        // server (§1.1) e l'unico evento che conta è "è arrivata roba nuova".
        NotificationCenter.default.publisher(for: .syncEngineCompleted)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.load() } }
            .store(in: &cancellables)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            sections = try await repository.fetchSections()
            lastError = nil
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
