import Foundation

/// L'ordine dei risultati di ricerca.
///
/// **Il difetto.** TMDB restituisce `/search/multi` nel suo ordine, che non è quello che l'utente
/// si aspetta: cercando "Spid" arrivavano prima film sconosciuti che contengono quella stringa, e
/// Spider-Man stava sotto. Chi cerca un titolo lo cerca **per nome**, e la popolarità serve solo a
/// sciogliere i pareggi.
///
/// **La formula.** Il testo pesa 0.60, la popolarità 0.25, il numero di voti 0.15. I livelli del
/// punteggio testuale distano 0.25 l'uno dall'altro — più del massimo contributo che popolarità e
/// voti insieme possono dare (0.40 · ma solo a parità di livello testuale, dove serve): un match
/// esatto non viene mai scavalcato da un "contiene" popolarissimo.
///
/// Tutto puro: nessuna rete, nessuno stato, verificabile riga per riga.
enum SearchRanking {

    /// Confronto senza accenti e senza maiuscole: "pokemon" deve trovare "Pokémon".
    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func score(result: SearchResult, query: String) -> Double {
        let q = normalize(query)
        let t = normalize(result.displayTitle)
        guard !q.isEmpty else { return 0 }

        let textScore: Double
        if t == q {
            textScore = 1.0
        } else if t.hasPrefix(q) {
            textScore = 0.75
        } else if t.split(separator: " ").contains(where: { $0.hasPrefix(q) }) {
            textScore = 0.55
        } else if t.contains(q) {
            textScore = 0.35
        } else {
            textScore = 0
        }

        let popScore = min(1.0, log10(1 + max(0, result.popularity ?? 0)) / 3.0)
        let voteScore = min(1.0, log10(1 + Double(result.voteCount ?? 0)) / 4.0)

        return 0.60 * textScore + 0.25 * popScore + 0.15 * voteScore
    }

    /// Ordina per punteggio decrescente. A parità: popolarità, poi id — così l'ordine è
    /// deterministico e la lista non balla fra due render.
    static func rank(_ results: [SearchResult], query: String) -> [SearchResult] {
        results
            .map { (result: $0, score: score(result: $0, query: query)) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let lPop = lhs.result.popularity ?? 0
                let rPop = rhs.result.popularity ?? 0
                if lPop != rPop { return lPop > rPop }
                return lhs.result.id < rhs.result.id
            }
            .map(\.result)
    }
}
