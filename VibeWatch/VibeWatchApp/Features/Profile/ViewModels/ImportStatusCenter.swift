import Foundation
import Combine

/// Redesign 2.0 dell'import — il punto UNICO che tiene d'occhio l'import per tutta l'app.
///
/// Prima ogni schermata (onboarding, ImportView) creava il proprio `ImportViewModel`: appena
/// la schermata moriva, l'import diventava invisibile. Qui il ViewModel è uno e condiviso —
/// l'onboarding lo usa per la card, la home per il banner, il profilo per l'inbox — e il
/// polling sopravvive alla navigazione: parte quando c'è un job aperto e si spegne da solo
/// quando il job finisce.
///
/// Il centro NON duplica lo stato del ViewModel: lo osserva e ci deriva sopra le tre cose
/// sue — il banner della home, il toast di fine import, la memoria dei banner già chiusi.
@MainActor
final class ImportStatusCenter: ObservableObject {

    static let shared = ImportStatusCenter()

    /// L'oblò condiviso. Chiunque mostri l'import osserva QUESTO, mai una copia.
    let importViewModel: ImportViewModel

    /// Il banner sotto l'header di Scopri, derivato da stato + progresso + memoria dei
    /// banner chiusi. `hidden` copre anche "nessun import mai fatto".
    enum Banner: Equatable {
        case hidden
        case running(fraction: Double, processed: Int?, total: Int?)
        /// Import concluso con titoli nell'inbox: "N titoli da verificare su M" + Gestisci.
        case review(pending: Int, totalEpisodes: Int)
        /// Import concluso e pulito: card verde con i numeri + OK.
        case success(serie: Int, episodi: Int, film: Int)
    }

    /// La pagina "Titoli da verificare" da presentare (banner "Gestisci", tap sulla push,
    /// riga del profilo). La osserva DiscoveryView.
    @Published var showReviewSheet = false

    /// Il toast "Libreria importata · N titoli da verificare", una volta sola per job.
    @Published var toastMessage: String?

    /// I job il cui banner di successo è stato chiuso con OK: non deve ricomparire al
    /// prossimo lancio. Persistito perché il banner vive più a lungo del processo.
    @Published private(set) var dismissedJobIds: Set<String>

    private static let dismissedKey = "import.banner.dismissedJobs"
    private var cancellable: AnyCancellable?
    private var started = false

    init(importViewModel: ImportViewModel? = nil,
         userDefaults: UserDefaults = .standard) {
        self.importViewModel = importViewModel ?? ImportViewModel()
        self.userDefaults = userDefaults
        self.dismissedJobIds = Set(
            userDefaults.stringArray(forKey: Self.dismissedKey) ?? [])
        // Un ObservableObject annidato non propaga da solo: il banner deve ridisegnarsi a
        // ogni giro di polling del ViewModel condiviso.
        cancellable = self.importViewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            // Il toast va deciso DOPO che il nuovo stato è pubblicato.
            Task { @MainActor [weak self] in self?.reactToStateChange() }
        }
    }

    private let userDefaults: UserDefaults

    /// Al lancio (e dopo un sign-in): ritrova l'import in corso o l'ultimo concluso.
    /// Idempotente — la seconda chiamata non fa niente.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        Task { await importViewModel.loadExisting() }
    }

    // MARK: - Derivazioni

    var banner: Banner {
        switch importViewModel.state {
        case .sources, .failed:
            // Il fallimento ha già la sua schermata dedicata (ImportView/onboarding): un
            // banner d'errore in home sarebbe un secondo posto da tenere coerente.
            return .hidden
        case .uploading:
            return .running(fraction: 0.02, processed: nil, total: nil)
        case .running:
            let progress = importViewModel.progress
            return .running(fraction: progress?.fraction ?? 0.05,
                            processed: progress?.processedEpisodes,
                            total: progress?.totalEpisodes)
        case .done(let report):
            let pending = report.reviewItems.count
            if pending > 0 {
                return .review(pending: pending,
                               totalEpisodes: report.episodiImportati
                                   + report.nonRiconosciutiEpisodi)
            }
            if let jobId = importViewModel.doneJobId, dismissedJobIds.contains(jobId) {
                return .hidden
            }
            return .success(serie: report.serieImportate,
                            episodi: report.episodiImportati,
                            film: report.filmImportati)
        }
    }

    /// L'OK del banner verde: chiuso ora e per sempre, per QUESTO job.
    func dismissSuccessBanner() {
        guard let jobId = importViewModel.doneJobId else { return }
        dismissedJobIds.insert(jobId)
        userDefaults.set(Array(dismissedJobIds), forKey: Self.dismissedKey)
        objectWillChange.send()
    }

    /// Il tap sulla push `import_done`: si arriva in home con l'inbox già aperto, se c'è
    /// qualcosa da gestire. Il report a schermo può essere vecchio: prima si rilegge.
    func handleImportPushTap() {
        Task { @MainActor in
            if case .sources = importViewModel.state {
                started = true
                await importViewModel.loadExisting()
            } else {
                await importViewModel.refreshReport()
            }
            if case .done(let report) = importViewModel.state,
               !report.reviewItems.isEmpty {
                showReviewSheet = true
            }
        }
    }

    // MARK: - Toast di fine import

    /// L'ultimo job per cui il toast è già uscito: una volta sola, anche se lo stato
    /// ripassa da `done` (per esempio dopo un'esclusione che rilegge il report).
    private var toastShownForJob: String?
    /// C'è stato un tratto `running` in questa sessione? Il toast ha senso solo al
    /// PASSAGGIO a concluso — non alla ripresa di un job finito ieri.
    private var sawRunning = false
    /// Quanti titoli erano nell'inbox all'ultimo `done` visto: se lo stato torna `running`
    /// è una RIAPERTURA (mapping manuale) e a fine giro il toast racconta il delta
    /// ("N risolti, X ancora da verificare"), non un generico "libreria importata".
    private var lastDonePending: Int?
    private var pendingAtReopen: Int?

    private func reactToStateChange() {
        switch importViewModel.state {
        case .uploading, .running:
            sawRunning = true
            if pendingAtReopen == nil, let last = lastDonePending {
                pendingAtReopen = last
                // Il giro di mapping merita il SUO toast anche sullo stesso job.
                toastShownForJob = nil
            }
        case .done(let report):
            let pending = report.reviewItems.count
            defer { lastDonePending = pending }
            guard sawRunning, let jobId = importViewModel.doneJobId,
                  toastShownForJob != jobId else { return }
            toastShownForJob = jobId
            if let before = pendingAtReopen {
                // Fine di un giro di mapping manuale: il racconto giusto è il delta.
                pendingAtReopen = nil
                let solved = max(0, before - pending)
                toastMessage = pending > 0
                    ? String(format: "import.toast.mapping.partial".localized, solved, pending)
                    : String(format: "import.toast.mapping.done".localized, solved)
            } else {
                toastMessage = pending > 0
                    ? String(format: "import.toast.imported.review".localized, pending)
                    : "import.toast.imported".localized
            }
        case .sources, .failed:
            break
        }
    }
}
