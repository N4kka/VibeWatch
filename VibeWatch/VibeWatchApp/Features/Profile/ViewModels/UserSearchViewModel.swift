import Foundation

/// SPEC v3 §3.7 — la ricerca utenti.
///
/// Il client non decide niente: superficie pubblica, blocchi nei due versi e ordine stanno in
/// `search_users`. Qui c'è solo il debounce — un giro di rete per carattere sarebbe la stessa
/// cosa da cui `UsernameSetupViewModel` si difende — e la distinzione fra tre stati che a
/// schermo non si somigliano: "non ho ancora cercato", "nessun risultato", "la ricerca è
/// fallita". Schiacciarli l'uno sull'altro è la forma di silenzio di questa sessione.
@MainActor
final class UserSearchViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle              // niente query: si mostra l'invito
        case searching
        case results([PublicProfile])
        case empty             // query vera, zero risultati
        case failed            // errore di rete: si dice, non si finge "nessuno"
    }

    @Published private(set) var phase: Phase = .idle

    @Published var query: String = "" {
        didSet { scheduleSearch() }
    }

    private let search: (String) async throws -> [PublicProfile]
    private var searchTask: Task<Void, Never>?
    private let debounce: Duration

    init(search: ((String) async throws -> [PublicProfile])? = nil,
         debounce: Duration = .milliseconds(300)) {
        self.search = search ?? { try await SupabaseService.shared.searchUsers($0) }
        self.debounce = debounce
    }

    private func scheduleSearch() {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .idle
            return
        }

        phase = .searching
        searchTask = Task { [weak self, debounce, search] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let outcome: Phase
            do {
                let found = try await search(trimmed)
                outcome = found.isEmpty ? .empty : .results(found)
            } catch {
                outcome = .failed
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
                else { return }   // ha continuato a scrivere
                self.phase = outcome
            }
        }
    }
}
