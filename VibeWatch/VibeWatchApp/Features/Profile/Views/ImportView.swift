import SwiftUI
import UniformTypeIdentifiers

/// SPEC v3 §7 — "Import from". Oggi una sorgente sola, TV Time (.zip), ma la schermata è una
/// lista apposta: gli import futuri sono righe nuove, non schermate nuove.
///
/// La vista è un oblò sul job (§7.2: lo stato vive sul server, le fasi le muove il cron):
/// l'unico tratto che richiede l'app aperta è l'upload. Appena il job esiste lo si dice
/// esplicitamente — "puoi chiudere l'app" — perché è la promessa della spec, non un dettaglio.
@MainActor
struct ImportView: View {
    @StateObject private var viewModel: ImportViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    /// Tutte le righe risolvibili del report: lo sheet raccoglie le scelte senza avviare il job.
    @State private var risoluzioneBatch: ImportManualResolveBatch?

    init(viewModel: ImportViewModel? = nil) {
        // Il default sta QUI e non nella firma: un default argument è nonisolated, e il
        // ViewModel è @MainActor.
        _viewModel = StateObject(wrappedValue: viewModel ?? ImportViewModel())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("import.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BackCircleButton { dismiss() }
                }
            }
            .task { await viewModel.loadExisting() }
            .onDisappear { viewModel.stopPolling() }
            .fileImporter(isPresented: $showPicker,
                          allowedContentTypes: [.zip]) { result in
                if case .success(let url) = result {
                    Task { await viewModel.importFile(at: url) }
                }
                // Il picker annullato non è un errore: si resta sulle sorgenti.
            }
            .sheet(item: $risoluzioneBatch) { batch in
                ImportManualResolveSheet(items: batch.items, viewModel: viewModel)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .sources:
            sourcesList
        case .uploading:
            statusPanel(icon: nil, titleKey: "import.state.uploading",
                        subtitleKey: "import.state.uploadingHint", spinning: true)
        case .running(_, let phase):
            statusPanel(icon: nil, titleKey: phaseKey(phase),
                        subtitleKey: "import.canClose", spinning: true)
        case .done(let report):
            reportView(report)
        case .failed(let messageKey, let detail, _):
            failedView(messageKey: messageKey, detail: detail)
        }
    }

    // MARK: - Sorgenti

    private var sourcesList: some View {
        List {
            Section {
                Button {
                    showPicker = true
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 20))
                            .foregroundColor(.theme.accentOrange)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("import.source.tvtime".localized)
                                .font(.system(size: 16))
                                .foregroundColor(.theme.textPrimary)
                            Text("import.source.tvtime.subtitle".localized)
                                .font(.system(size: 13))
                                .foregroundColor(.theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.white.opacity(0.05))
            } footer: {
                Text("import.source.footer".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.theme.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Stato in corso

    private func statusPanel(icon: String?, titleKey: String, subtitleKey: String,
                             spinning: Bool) -> some View {
        VStack(spacing: 14) {
            if spinning {
                ProgressView().controlSize(.large)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundColor(.theme.textSecondary)
            }
            Text(titleKey.localized)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
            Text(subtitleKey.localized)
                .font(.system(size: 14))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func phaseKey(_ phase: String) -> String {
        switch phase {
        case "uploaded":    return "import.phase.queued"
        case "parsing":     return "import.phase.parsing"
        case "resolving":   return "import.phase.resolving"
        case "writing":     return "import.phase.writing"
        case "recomputing": return "import.phase.finishing"
        default:            return "import.phase.queued"
        }
    }

    // MARK: - Report (§7.4)

    private func reportView(_ report: ImportReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    reportNumber(report.episodiImportati, key: "import.report.episodes")
                    reportNumber(report.serieImportate, key: "import.report.shows")
                }
                .frame(maxWidth: .infinity)

                if let dal = report.dal.flatMap(Self.shortDate),
                   let al = report.al.flatMap(Self.shortDate) {
                    Text(String(format: "import.report.period".localized, dal, al))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                // §7.1: gli stati per-serie ripristinati (watchlist e archivio). Solo per i job
                // che li supportano: su un report vecchio l'assenza non è uno zero.
                if report.statiSupportati && report.statiSerieImportati > 0 {
                    Text(String(format: "import.report.statusesApplied".localized,
                                report.statiSerieImportati))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if report.statiSupportati && report.statiSerieNonRisolti > 0 {
                    Text(String(format: "import.report.statusesUnresolved".localized,
                                report.statiSerieNonRisolti))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                // §7.5: i voti. Su un job nuovo le stelle sono in `user_ratings` e si contano
                // (comprese quelle lasciate al voto già dato in app: non è una perdita); su un
                // job vecchio resta la riga "non ancora importati" — uno zero muto sarebbe
                // indistinguibile da "non ne avevi".
                if report.votiImportati && report.votiStelleImportati > 0 {
                    Text(String(format: "import.report.ratingsApplied".localized,
                                report.votiStelleImportati))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if report.votiImportati && report.votiStelleNonRisolti > 0 {
                    Text(String(format: "import.report.ratingsUnresolved".localized,
                                report.votiStelleNonRisolti))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                // §7.1: i Favorites — solo per i job che li supportano, e solo se c'è qualcosa
                // da dire. Slot pieni e già favoriti non sono perdite: non allarmano.
                if report.favoritesSupportati && report.favoritesImportati > 0 {
                    Text(String(format: "import.report.favoritesApplied".localized,
                                report.favoritesImportati))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if report.favoritesSupportati && report.favoriteFilmNonSupportati > 0 {
                    Text(String(format: "import.report.favoriteMoviesUnsupported".localized,
                                report.favoriteFilmNonSupportati))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if report.votiStelle + report.votiReaction > 0 && !report.votiImportati {
                    Text(String(format: "import.report.ratingsDeferred".localized,
                                report.votiStelle + report.votiReaction))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                // §7.1: i film di v1 — visti e watchlist su righe separate (destinazioni
                // diverse); i già in lista non allarmano, i non risolti finiscono già
                // nell'elenco dei non riconosciuti del server via `film_non_risolti`.
                if report.filmSupportati && report.filmImportati > 0 {
                    Text(String(format: "import.report.moviesApplied".localized,
                                report.filmImportati))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if report.filmSupportati && report.filmWatchlistImportati > 0 {
                    Text(String(format: "import.report.moviesWatchlistApplied".localized,
                                report.filmWatchlistImportati))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if report.filmSupportati && report.filmNonRisolti > 0 {
                    Text(String(format: "import.report.moviesUnresolved".localized,
                                report.filmNonRisolti))
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                // §7.4: "N elementi non riconosciuti, con l'elenco dei titoli". Senza abbellire.
                if report.nonRiconosciutiEpisodi > 0 {
                    let risolvibili = report.nonRiconosciutiElenco.filter {
                        $0.tvdbSeriesId != nil
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(format: "import.report.unresolvedTitle".localized,
                                    report.nonRiconosciutiEpisodi))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.theme.textPrimary)
                        ForEach(report.nonRiconosciutiElenco, id: \.titolo) { item in
                            HStack(alignment: .center, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.titolo)
                                        .font(.system(size: 14))
                                        .foregroundColor(.theme.textPrimary)
                                    Text(String(format: "import.report.unresolvedRow".localized,
                                                item.episodi) + " · " + item.motivo)
                                        .font(.system(size: 12))
                                        .foregroundColor(.theme.textSecondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                        if !risolvibili.isEmpty {
                            Button {
                                risoluzioneBatch = ImportManualResolveBatch(items: risolvibili)
                            } label: {
                                Text(String(format: "import.resolve.batchButton".localized,
                                            risolvibili.count))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.theme.accentOrange)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.05)))
                } else {
                    Text("import.report.allResolved".localized)
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Button("common.done".localized) { dismiss() }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.theme.accentOrange)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
            }
            .padding()
        }
    }

    private func reportNumber(_ value: Int, key: String) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            Text(key.localized)
                .font(.system(size: 13))
                .foregroundColor(.theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }

    /// Le date del report sono timestamp ISO del server: qui si mostra solo il giorno.
    private static func shortDate(_ iso: String) -> String? {
        String(iso.prefix(10)).isEmpty ? nil : String(iso.prefix(10))
    }

    // MARK: - Fallito

    private func failedView(messageKey: String, detail: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(.theme.textSecondary)
            Text(messageKey.localized)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .multilineTextAlignment(.center)
            if let detail, !detail.isEmpty {
                // La verità tecnica, piccola ma visibile: §7.4 vieta di abbellire.
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Button("common.retry".localized) {
                Task { await viewModel.retry() }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.theme.accentOrange)
            .padding(.top, 4)
        }
        .padding()
    }
}

// MARK: - Risoluzione a mano (§7.4)

struct ImportManualResolveBatch: Identifiable {
    let id = UUID()
    let items: [ImportReport.Unresolved]
}

extension ImportReport.Unresolved: Identifiable {
    /// L'id TVDB è unico dentro l'elenco; il titolo copre difensivamente le righe senza id.
    public var id: String { tvdbSeriesId ?? titolo }
}

/// Raccoglie prima tutte le corrispondenze e solo dopo avvia un unico retry dell'import.
/// La scelta di un risultato TMDB è quindi locale e correggibile: nessun titolo fa ripartire
/// da solo una serie lunga mentre l'utente sta ancora lavorando sugli altri.
@MainActor
struct ImportManualResolveSheet: View {
    let items: [ImportReport.Unresolved]
    @ObservedObject var viewModel: ImportViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedShows: [String: TVShow] = [:]
    @State private var activeItemId: String?
    @State private var query: String = ""
    @State private var results: [TVShow] = []
    @State private var searching = false
    @State private var searchFailed = false
    @State private var submitting = false

    private var activeItem: ImportReport.Unresolved? {
        items.first { $0.id == activeItemId }
    }

    private var isComplete: Bool {
        !items.isEmpty && items.allSatisfy { selectedShows[$0.id] != nil }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.theme.background.ignoresSafeArea()
                if let activeItem {
                    searchView(for: activeItem)
                } else {
                    batchSummary
                }
            }
            .navigationTitle("import.resolve.button".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if activeItemId == nil { dismiss() } else { activeItemId = nil }
                    } label: {
                        if activeItemId == nil {
                            Text("common.cancel".localized)
                        } else {
                            Image(systemName: "chevron.left")
                        }
                    }
                    .disabled(submitting)
                }
            }
        }
    }

    private var batchSummary: some View {
        VStack(spacing: 12) {
            Text("import.resolve.batchHint".localized)
                .font(.system(size: 13))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text(String(format: "import.resolve.batchProgress".localized,
                        selectedShows.count, items.count))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.theme.textPrimary)

            if let errore = viewModel.manualResolveError {
                Text("import.resolve.failed".localized + " " + errore)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            List(items) { item in
                Button { openSearch(for: item) } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.titolo)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.theme.textPrimary)
                            if let show = selectedShows[item.id] {
                                Text(show.name)
                                    .font(.system(size: 12))
                                    .foregroundColor(.theme.accentOrange)
                            } else {
                                Text("import.resolve.searchPlaceholder".localized)
                                    .font(.system(size: 12))
                                    .foregroundColor(.theme.textSecondary)
                            }
                        }
                        Spacer()
                        Image(systemName: selectedShows[item.id] == nil
                              ? "chevron.right" : "checkmark.circle.fill")
                            .foregroundColor(selectedShows[item.id] == nil
                                             ? .theme.textSecondary : .theme.accentOrange)
                    }
                }
                .disabled(submitting)
                .listRowBackground(Color.white.opacity(0.05))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Button {
                Task { await submitBatch() }
            } label: {
                if submitting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("import.resolve.startBatch".localized)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
            }
            .foregroundColor(.theme.accentOrange)
            .disabled(!isComplete || submitting)
            .opacity(isComplete ? 1 : 0.45)
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .padding(.top, 12)
    }

    private func searchView(for item: ImportReport.Unresolved) -> some View {
        VStack(spacing: 12) {
            Text(String(format: "import.resolve.title".localized, item.titolo))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("import.resolve.hint".localized)
                .font(.system(size: 12))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            TextField("import.resolve.searchPlaceholder".localized, text: $query)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .padding(.horizontal)
                .onSubmit { Task { await search() } }

            if searching {
                ProgressView().frame(maxHeight: .infinity)
            } else if searchFailed {
                VStack(spacing: 8) {
                    Text("import.resolve.searchFailed".localized)
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                    Button("common.retry".localized) { Task { await search() } }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.accentOrange)
                }
                .frame(maxHeight: .infinity)
            } else if results.isEmpty {
                Text("import.resolve.empty".localized)
                    .font(.system(size: 13))
                    .foregroundColor(.theme.textSecondary)
                    .frame(maxHeight: .infinity)
            } else {
                List(results) { show in
                    Button { select(show, for: item) } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(show.name)
                                    .font(.system(size: 15))
                                    .foregroundColor(.theme.textPrimary)
                                if let anno = show.firstAirDate?.prefix(4), !anno.isEmpty {
                                    Text(String(anno))
                                        .font(.system(size: 12))
                                        .foregroundColor(.theme.textSecondary)
                                }
                            }
                            Spacer()
                            if selectedShows[item.id]?.id == show.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.theme.accentOrange)
                            }
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.top, 12)
    }

    private func openSearch(for item: ImportReport.Unresolved) {
        activeItemId = item.id
        query = item.titolo
        results = []
        searchFailed = false
        Task { await search() }
    }

    private func search() async {
        let testo = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !testo.isEmpty else { return }
        searching = true
        searchFailed = false
        do {
            results = try await TMDBService.shared.searchTVShows(query: testo, page: 1).results
        } catch {
            results = []
            searchFailed = true
        }
        searching = false
    }

    private func select(_ show: TVShow, for item: ImportReport.Unresolved) {
        selectedShows[item.id] = show
        if let next = items.first(where: { selectedShows[$0.id] == nil }) {
            openSearch(for: next)
        } else {
            activeItemId = nil
        }
    }

    private func submitBatch() async {
        guard isComplete else { return }
        let resolutions = items.compactMap { item -> ImportManualResolution? in
            guard let tvdbId = item.tvdbSeriesId, let show = selectedShows[item.id] else {
                return nil
            }
            return ImportManualResolution(tvdbSeriesId: tvdbId, tmdbShowId: show.id)
        }
        guard resolutions.count == items.count else { return }
        submitting = true
        let ok = await viewModel.resolveManually(resolutions)
        submitting = false
        // Solo qui parte il job. Il polling ricaricherà il report e farà sparire le righe risolte.
        if ok { dismiss() }
    }
}
