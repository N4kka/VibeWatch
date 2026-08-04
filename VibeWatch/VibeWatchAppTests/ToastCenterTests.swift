import XCTest
@testable import VibeWatchApp

/// Il `ToastCenter` è l'unico punto in cui passano i riscontri delle azioni: se un toast di
/// progresso viene scavalcato, l'utente vede "fatto" prima che l'operazione sia finita.
@MainActor
final class ToastCenterTests: XCTestCase {

    /// Un centro senza attese reali e senza finestra UIKit: i test guardano la macchina a stati.
    private func makeCenter() -> ToastCenter {
        let center = ToastCenter()
        center.mounter = {}
        center.sleeper = { _ in await Task.yield() }
        return center
    }

    func testBeginMostraLaFaseDiProgresso() {
        let center = makeCenter()
        center.begin(id: "op", message: "Aggiunta…")

        XCTAssertEqual(center.current?.id, "op")
        XCTAssertEqual(center.current?.phase, .progress)
        XCTAssertEqual(center.current?.message, "Aggiunta…")
    }

    func testCompleteMostraIlSuccessoEPoiSparisce() async {
        let center = makeCenter()
        let id = center.begin(message: "Aggiunta…")
        center.complete(id, message: "Aggiunto")

        await attendiFase(center, .success)
        XCTAssertEqual(center.current?.phase, .success)
        XCTAssertEqual(center.current?.message, "Aggiunto")

        await attendiCongedo(center)
        XCTAssertNil(center.current)
    }

    func testFailMostraLErroreEPoiSparisce() async {
        let center = makeCenter()
        let id = center.begin(message: "Aggiunta…")
        center.fail(id, message: "Non riuscito")

        await attendiFase(center, .failure)
        XCTAssertEqual(center.current?.phase, .failure)
        XCTAssertEqual(center.current?.message, "Non riuscito")

        await attendiCongedo(center)
        XCTAssertNil(center.current)
    }

    /// Un toast di progresso non si interrompe: chi arriva dopo aspetta il suo turno.
    func testUnProgressoInCorsoNonVieneScavalcato() async {
        let center = makeCenter()
        let id = center.begin(message: "Operazione lunga…")
        center.show(success: "Altro riscontro")

        XCTAssertEqual(center.current?.id, id)
        XCTAssertEqual(center.current?.phase, .progress)

        center.complete(id, message: "Finita")
        await attendiFase(center, .success)
        XCTAssertEqual(center.current?.message, "Finita")

        await attendiCongedo(center)
        XCTAssertEqual(center.current?.message, "Altro riscontro")
    }

    /// La coda è limitata a 3: oltre, il più vecchio in attesa cede il posto.
    func testLaCodaScartaIlPiuVecchioOltreIlLimite() async {
        let center = makeCenter()
        let id = center.begin(message: "Operazione lunga…")
        center.show(success: "primo")
        center.show(success: "secondo")
        center.show(success: "terzo")
        center.show(success: "quarto")

        center.complete(id, message: "Finita")
        await attendiFase(center, .success)
        await attendiCongedo(center)

        // "primo" è stato scartato: la coda riparte da "secondo".
        XCTAssertEqual(center.current?.message, "secondo")
    }

    /// Un toast terminale viene sostituito subito: non c'è motivo di far attendere un riscontro.
    func testUnToastTerminaleVieneSostituitoSubito() {
        let center = makeCenter()
        center.show(success: "primo")
        center.show(success: "secondo")

        XCTAssertEqual(center.current?.message, "secondo")
    }

    func testRunRilanciaLErroreEMostraIlFallimento() async {
        struct Boom: Error {}
        let center = makeCenter()

        do {
            try await center.run("In corso…", success: "Fatto", failure: "Non riuscito") {
                throw Boom()
            }
            XCTFail("run deve rilanciare l'errore dell'operazione")
        } catch {
            XCTAssertTrue(error is Boom)
        }

        await attendiFase(center, .failure)
        XCTAssertEqual(center.current?.phase, .failure)
        XCTAssertEqual(center.current?.message, "Non riuscito")
    }

    func testRunRestituisceIlValoreEMostraIlSuccesso() async throws {
        let center = makeCenter()
        let valore = try await center.run("In corso…", success: "Fatto") { 42 }

        XCTAssertEqual(valore, 42)
        await attendiFase(center, .success)
        XCTAssertEqual(center.current?.phase, .success)
        XCTAssertEqual(center.current?.message, "Fatto")
    }

    /// La fase di progresso resta a schermo per una durata minima: un `complete` immediato non
    /// deve far sparire la barra prima che l'occhio la veda.
    func testIlProgressoRestaVisibileFinoAllaDurataMinima() async {
        let center = ToastCenter()
        center.mounter = {}
        let registro = RegistroAttese()
        // Un'attesa lunga ma finita: la fase terminale resta in coda per tutto il test.
        center.sleeper = { seconds in
            registro.attese.append(seconds)
            for _ in 0..<500 { await Task.yield() }
        }

        let id = center.begin(message: "In corso…")
        center.complete(id, message: "Fatto")

        // Qualche turno perché il Task della durata minima parta e registri l'attesa.
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(registro.attese.first, ToastCenter.Delay.minimumProgress)
        XCTAssertEqual(center.current?.phase, .progress)
        XCTAssertEqual(center.current?.message, "In corso…")

        center.reset()
    }

    /// Scaduta la durata minima, l'esito arriva senza bisogno di un secondo `complete`.
    func testLEsitoArrivaQuandoLaDurataMinimaEScaduta() async {
        let center = makeCenter()
        let id = center.begin(message: "In corso…")
        center.complete(id, message: "Fatto")

        await attendiFase(center, .success)
        XCTAssertEqual(center.current?.phase, .success)
        XCTAssertEqual(center.current?.message, "Fatto")
    }

    // MARK: - Attesa

    /// Raccoglie le durate chieste allo sleeper senza catturare una variabile locale.
    private final class RegistroAttese {
        var attese: [TimeInterval] = []
    }

    /// La transizione alla fase terminale passa dal `Task` della durata minima.
    private func attendiFase(_ center: ToastCenter, _ fase: ToastCenter.Toast.Phase) async {
        for _ in 0..<50 {
            if center.current?.phase == fase { return }
            await Task.yield()
        }
    }

    /// Il congedo automatico gira su un `Task`: qui si cedono alcuni turni finché non scatta.
    private func attendiCongedo(_ center: ToastCenter) async {
        let atteso = center.current
        for _ in 0..<50 {
            await Task.yield()
            if center.current != atteso { return }
        }
    }
}
