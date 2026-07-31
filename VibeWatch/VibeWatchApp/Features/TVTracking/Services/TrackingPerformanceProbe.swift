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
    static func begin() {
        let id = OSSignpostID(log: log)
        signpostID = id
        startedAt = CFAbsoluteTimeGetCurrent()
        dataReadyAt = nil
        os_signpost(.begin, log: log, name: intervalName, signpostID: id)
    }

    /// I dati sono in mano al ViewModel. Non è ancora la fine: manca il disegno, che su una lista
    /// con immagini è spesso la parte più costosa — misurare solo fin qui darebbe un numero
    /// lusinghiero e falso.
    static func dataReady(rows: Int) {
        guard let start = startedAt, let id = signpostID else { return }
        dataReadyAt = CFAbsoluteTimeGetCurrent()
        os_signpost(.event, log: log, name: intervalName, signpostID: id,
                    "dati pronti: %d righe", rows)
        printer.info("§13.6 dati pronti in \(Self.ms(from: start), privacy: .public) ms (\(rows) righe)")
    }

    /// Il primo fotogramma con contenuto è a schermo.
    ///
    /// È un'approssimazione dichiarata: SwiftUI non espone "il frame è stato presentato", quindi
    /// il punto di arrivo è il turno di runloop successivo alla comparsa del primo elemento —
    /// dopo cioè che il layout è stato calcolato e il commit inviato. Sbaglia per meno di un
    /// fotogramma (16 ms a 60 Hz), che su un budget di 300 ms non cambia il verdetto.
    static func firstFrameRendered() {
        guard let start = startedAt, let id = signpostID else { return }
        defer { startedAt = nil; signpostID = nil; dataReadyAt = nil }

        let total = Self.ms(from: start)
        let render = dataReadyAt.map { Self.ms(from: $0) }

        os_signpost(.end, log: log, name: intervalName, signpostID: id,
                    "totale %.1f ms", total)

        let verdetto = total <= 300 ? "OK" : "OLTRE IL BUDGET"
        if let render {
            printer.info("""
            §13.6 \(verdetto, privacy: .public): totale \(total, privacy: .public) ms \
            (dati + disegno \(render, privacy: .public) ms) — budget 300 ms
            """)
        } else {
            printer.info("§13.6 \(verdetto, privacy: .public): totale \(total, privacy: .public) ms — budget 300 ms")
        }
    }

    private static func ms(from t: CFAbsoluteTime) -> Double {
        ((CFAbsoluteTimeGetCurrent() - t) * 1000 * 10).rounded() / 10
    }
}
