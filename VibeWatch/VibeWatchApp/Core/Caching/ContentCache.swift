import Foundation

/// Cache generica unica (Fase 3 §1.4): **TTL + capacità + eviction LRU automatica** costruita
/// su `NSCache`, che si svuota da sola sotto memory pressure (a differenza di un `Dictionary`).
///
/// Sostituisce le cache ad-hoc sparse nei servizi (`MovieReactionService.countsCache`,
/// `DiscoveryPersonalizationService.memoryCache`, `*.cachedClips`, ...) che crescevano senza
/// limite né invalidazione, tenendo in RAM copie multiple dello stesso contenuto (2.1).
///
/// `NSCache` è già thread-safe; l'attore serializza comunque l'accesso e offre un'API async
/// naturale per i call-site (per lo più `@MainActor` o attori). In Swift 5 mode i `Value`
/// non-Sendable attraversano il confine d'attore senza errori.
actor ContentCache<Key: Hashable, Value> {

    /// NSCache richiede chiavi/valori reference-type: incapsuliamo `Key` e l'entry in classi.
    private final class WrappedKey: NSObject {
        let key: Key
        init(_ key: Key) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool {
            (object as? WrappedKey).map { $0.key == key } ?? false
        }
    }

    private final class Entry {
        let value: Value
        let expiresAt: Date
        init(value: Value, expiresAt: Date) {
            self.value = value
            self.expiresAt = expiresAt
        }
    }

    private let store = NSCache<WrappedKey, Entry>()
    private let ttl: TimeInterval

    /// - Parameters:
    ///   - ttl: tempo di vita di ogni entry (secondi).
    ///   - countLimit: numero massimo di entry (0 = illimitato; NSCache evince in modo best-effort).
    ///   - totalCostLimit: costo totale massimo (0 = illimitato); usa il `cost` passato a `insert`.
    init(ttl: TimeInterval, countLimit: Int = 0, totalCostLimit: Int = 0) {
        self.ttl = ttl
        store.countLimit = countLimit
        store.totalCostLimit = totalCostLimit
    }

    /// Restituisce il valore se presente e non scaduto; altrimenti `nil` (rimuovendo l'entry scaduta).
    func value(for key: Key) -> Value? {
        let wrapped = WrappedKey(key)
        guard let entry = store.object(forKey: wrapped) else { return nil }
        guard entry.expiresAt > Date() else {
            store.removeObject(forKey: wrapped)  // scaduta → libera subito
            return nil
        }
        return entry.value
    }

    func insert(_ value: Value, for key: Key, cost: Int = 1) {
        let entry = Entry(value: value, expiresAt: Date().addingTimeInterval(ttl))
        store.setObject(entry, forKey: WrappedKey(key), cost: max(cost, 0))
    }

    func removeValue(for key: Key) {
        store.removeObject(forKey: WrappedKey(key))
    }

    func removeAll() {
        store.removeAllObjects()
    }
}
