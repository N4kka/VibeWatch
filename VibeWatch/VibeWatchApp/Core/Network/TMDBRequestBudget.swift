import Foundation

/// Budget per le richieste TMDB durante la generazione dei caroselli Discovery (4.1).
///
/// Senza budget, i ~27 generatori (ognuno con loop `for page in 1...5`) sparano un burst
/// di >100 richieste, molte IDENTICHE tra generatori diversi (es. `getTopRatedMovies(page:)`
/// usato da Hidden Gems, Staff Picks e Award Winners). Due leve:
///
///  - **coalescing**: richieste con la stessa `key` in volo contemporaneamente condividono
///    UN solo task; il risultato è poi servito da una cache a TTL breve, così le stesse
///    (endpoint, page) richieste in batch diversi durante la stessa generazione non ripartono.
///  - **maxConcurrent**: un semaforo asincrono limita quante richieste DISTINTE sono in volo
///    insieme, mettendo un tetto al fan-out invece di sparare tutto in una volta.
///
/// TTL volutamente breve: copre una singola passata di generazione (pochi secondi), non vuole
/// essere una cache di contenuti (quella è la cache Discovery su DB, ore).
actor TMDBRequestBudget {
    private let maxConcurrent: Int
    private let ttl: TimeInterval

    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inflight: [String: Task<Any, Error>] = [:]
    private var cache: [String: (value: Any, expires: Date)] = [:]

    /// Quanto costa davvero una passata di generazione. Il budget riduce duplicati e parallelismo,
    /// non il numero di richieste DISTINTE necessarie a riempire i caroselli: senza contarle non si
    /// sa se il collo di bottiglia è il fan-out o la latenza per richiesta.
    struct Stats: Sendable, Equatable {
        var cacheHits = 0
        var coalesced = 0
        var network = 0
        /// Chiavi distinte che hanno raggiunto la rete, per capire quanti endpoint diversi servono.
        var distinctNetworkKeys = 0

        var total: Int { cacheHits + coalesced + network }
    }

    private var stats = Stats()
    private var networkKeys: Set<String> = []

    /// Legge i contatori senza azzerarli.
    func currentStats() -> Stats {
        var snapshot = stats
        snapshot.distinctNetworkKeys = networkKeys.count
        return snapshot
    }

    /// Legge e azzera: da chiamare all'inizio di una generazione per misurarla in isolamento.
    @discardableResult
    func resetStats() -> Stats {
        let snapshot = currentStats()
        stats = Stats()
        networkKeys.removeAll()
        return snapshot
    }

    init(maxConcurrent: Int = 6, ttl: TimeInterval = 30) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.ttl = max(0, ttl)
    }

    /// Esegue `operation` sotto budget. `key` deve identificare univocamente (endpoint+parametri)
    /// E il tipo di ritorno: due key uguali devono produrre lo stesso tipo `T` (lo garantisce il
    /// decorator costruendo la key dal nome del metodo + parametri).
    func run<T>(key: String, _ operation: @escaping () async throws -> T) async throws -> T {
        // 1. Cache fresca → nessuna rete.
        if let entry = cache[key], entry.expires > Date(), let value = entry.value as? T {
            stats.cacheHits += 1
            return value
        }
        // 2. Richiesta identica già in volo → coalescing.
        if let existing = inflight[key] {
            stats.coalesced += 1
            return try await existing.value as! T
        }
        stats.network += 1
        networkKeys.insert(key)
        // 3. Nuova richiesta. `inflight[key]` è impostato SINCRONICAMENTE sotto, prima di
        //    qualsiasi await: i chiamatori concorrenti con la stessa key cadono nel ramo (2).
        let task = Task<Any, Error> { [weak self] in
            guard let self else { return try await operation() }
            await self.acquire()
            do {
                let value = try await operation()
                await self.finish(key: key, value: value)
                return value
            } catch {
                await self.finish(key: key, value: nil)
                throw error
            }
        }
        inflight[key] = task
        return try await task.value as! T
    }

    /// Svuota la cache (es. force refresh): la prossima generazione riparte senza riuso stale.
    func reset() {
        cache.removeAll()
    }

    // MARK: - Semaforo asincrono

    private func acquire() async {
        if active < maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
        // Risvegliato da release(): il permesso è stato ceduto direttamente (active invariato).
    }

    private func finish(key: String, value: Any?) {
        if let value {
            cache[key] = (value, Date().addingTimeInterval(ttl))
        }
        inflight[key] = nil
        pruneExpired()
        release()
    }

    private func release() {
        if !waiters.isEmpty {
            let cont = waiters.removeFirst()
            cont.resume()   // permesso ceduto a un'attesa: active resta invariato
        } else {
            active = max(0, active - 1)
        }
    }

    private func pruneExpired() {
        guard !cache.isEmpty else { return }
        let now = Date()
        cache = cache.filter { $0.value.expires > now }
    }
}
