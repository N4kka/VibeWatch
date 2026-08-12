import Foundation
import os.signpost

/// SPEC v3 §13.6 — la misura del requisito "la schermata Tracking renderizza da cache locale,
/// zero chiamate di rete, in meno di 300 ms".
///
/// **Perché serve strumentazione e non un cronometro.** A 300 ms il tempo di reazione umano (~250
/// ms) è dello stesso ordine di grandezza della cosa da misurare: un cronometro misurerebbe
/// soprattutto chi lo preme. Servono due cose che solo il codice può dare — l'istante esatto in
/// cui l'utente chiede la schermata, e l'istante in cui il primo fotogramma con contenuto è a
/// schermo.
///
/// Emette su due canali insieme, perché rispondono a domande diverse:
///
/// * **`os_signpost`** — leggibile da Instruments (template *Points of Interest*) e, soprattutto,
///   da un test con `XCTOSSignpostMetric`, che dà una distribuzione su più ripetizioni invece di
///   un aneddoto. È attivo anche in Release, che è la configurazione che conta: Swift in DEBUG non
///   è ottimizzato e misurarlo lì darebbe un numero pessimista e inutile.
/// * **un log in chiaro** — per leggere il numero dalla console senza aprire Instruments.
///
/// Il log passa da `os.Logger` e non dal `Logger` del progetto di proposito: quello è interamente
/// dentro `#if DEBUG` e in Release non stampa una riga, che è esattamente la configurazione in cui
/// questa misura va fatta.
enum TrackingPerformanceProbe {
    private static let log = OSLog(subsystem: "com.vibewatch.app", category: "Tracking")
    private static let printer = os.Logger(subsystem: "com.vibewatch.app", category: "TrackingPerf")

    /// Il nome dell'intervallo, da usare in un test con
    /// `XCTOSSignpostMetric(subsystem:category:name:)`.
    static let intervalName: StaticString = "TrackingFirstFrame"

    private static var startedAt: CFAbsoluteTime?
    private static var signpostID: OSSignpostID?
    private static var dataReadyAt: CFAbsoluteTime?

    /// L'utente ha chiesto la schermata. Da chiamare **prima** di qualunque lettura.
    ///
    /// - Parameter at: l'istante di partenza. Ha un default perché in produzione è sempre "adesso";
    ///   esiste come parametro perché la soglia di abbandono si prova solo potendo far passare
    ///   quaranta secondi, e aspettarli davvero in un test non è un'opzione.
    static func begin(at: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        let id = OSSignpostID(log: log)
        signpostID = id
        startedAt = at
        dataReadyAt = nil
        os_signpost(.begin, log: log, name: intervalName, signpostID: id)
    }

    /// I dati sono in mano al ViewModel.
    ///
    /// **Informativo, non un cancello.** Dice quanto è costata la lettura da SQLite, che è il pezzo
    /// che si può ottimizzare; ma può arrivare *dopo* il capolinea, e allora non c'è niente da
    /// annotare. Succede quando la schermata aveva già contenuto al momento del tap — il
    /// ViewModel si ricarica anche su `syncEngineCompleted`, quindi al primo `.task` le sezioni
    /// possono esserci già. In quel caso il numero giusto di §13.6 è "quasi zero", e gateare la
    /// chiusura su questo evento faceva scartare proprio la misura buona.
    static func dataReady(rows: Int) {
        guard let start = startedAt, let id = signpostID else { return }
        dataReadyAt = CFAbsoluteTimeGetCurrent()
        os_signpost(.event, log: log, name: intervalName, signpostID: id,
                    "dati pronti: %d righe", rows)
        printer.info("§13.6 dati pronti in \(Self.ms(from: start), format: .fixed(precision: 1), privacy: .public) ms (\(rows) righe)")
    }

    /// Il primo fotogramma con contenuto è a schermo.
    ///
    /// È un'approssimazione dichiarata: SwiftUI non espone "il frame è stato presentato", quindi
    /// il punto di arrivo è il turno di runloop successivo alla comparsa del primo elemento —
    /// dopo cioè che il layout è stato calcolato e il commit inviato. Sbaglia per meno di un
    /// fotogramma (16 ms a 60 Hz), che su un budget di 300 ms non cambia il verdetto.
    /// - Returns: i millisecondi misurati, o `nil` se la misura è stata scartata. Il valore di
    ///   ritorno esiste per il test: senza, l'unica prova che una misura sia stata scartata
    ///   sarebbe una riga di log, e la regola che questa funzione fa rispettare è già stata
    ///   violata una volta in silenzio.
    @discardableResult
    static func firstFrameRendered(at: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Double? {
        guard let start = startedAt, let id = signpostID else { return nil }

        // **Si disarma sempre**, anche quando si scarta. Nella prima misura sul dispositivo la
        // versione precedente scartava e lasciava il cronometro armato: quaranta secondi dopo,
        // tornando sulla tab, un secondo `onAppear` lo chiudeva e stampava
        // `OLTRE IL BUDGET: totale 40500.6 ms`. Un numero assurdo e' peggio di nessun numero,
        // perche' qualcuno potrebbe crederci.
        defer { startedAt = nil; signpostID = nil; dataReadyAt = nil }

        let total = Self.round1((at - start) * 1000)

        // Nessun fotogramma costa secondi. Oltre questa soglia non si sta misurando un disegno ma
        // un intervallo fra due cose scollegate — tipicamente un ritorno sulla tab molto dopo.
        guard total <= abandonAfterMs else {
            printer.error("""
            §13.6 misura abbandonata: \(total, format: .fixed(precision: 0), privacy: .public) ms \
            e' un intervallo, non un fotogramma. Riapri la tab per rifarla.
            """)
            return nil
        }

        os_signpost(.end, log: log, name: intervalName, signpostID: id,
                    "totale %.1f ms", total)

        let verdetto = total <= budgetMs ? "OK" : "OLTRE IL BUDGET"
        // Il tempo di lettura si annota solo se è arrivato prima: quando la schermata aveva già
        // contenuto, `dataReady` arriva dopo e sottrarlo darebbe un numero negativo.
        if let dataReady = dataReadyAt, dataReady <= at {
            let lettura = Self.round1((dataReady - start) * 1000)
            printer.info("""
            §13.6 \(verdetto, privacy: .public): totale \(total, format: .fixed(precision: 1), privacy: .public) ms \
            (di cui lettura \(lettura, format: .fixed(precision: 1), privacy: .public) ms) — budget \(Int(budgetMs), privacy: .public) ms
            """)
        } else {
            printer.info("""
            §13.6 \(verdetto, privacy: .public): totale \(total, format: .fixed(precision: 1), privacy: .public) ms \
            (schermata già popolata) — budget \(Int(budgetMs), privacy: .public) ms
            """)
        }
        return total
    }

    /// Il budget di §13.6, in millisecondi. Sta qui e non sparso fra il verdetto e i test.
    static let budgetMs: Double = 300

    /// Oltre questa soglia non si sta più misurando un fotogramma. Larga di proposito: deve
    /// scartare l'assurdo (i 40 s osservati), non arbitrare fra "lento" e "molto lento" — quello
    /// lo fa `budgetMs`, e un 900 ms vero va visto, non nascosto.
    static let abandonAfterMs: Double = 5_000

    private static func ms(from t: CFAbsoluteTime) -> Double {
        round1((CFAbsoluteTimeGetCurrent() - t) * 1000)
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
