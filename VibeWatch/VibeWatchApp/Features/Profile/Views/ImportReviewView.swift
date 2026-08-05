import SwiftUI

// MARK: - ViewModel

/// Redesign 2.0 — "Titoli da verificare": l'inbox dei non riconosciuti dell'import.
///
/// Le scelte restano LOCALI finché l'utente non tocca "Importa N titoli": un solo giro di
/// risoluzione per tutto il batch (il vincolo di §7.4), mai un import per titolo. L'unica
/// azione immediata è "Escludi", che è una decisione definitiva e non riapre il job.
///
/// I candidati con la percentuale di somiglianza si calcolano QUI, con la ricerca TMDB che
/// il client ha già: il server non conosce candidati — quando la pipeline fallisce non ha
/// nessun match da proporre — e la percentuale è dichiaratamente un'euristica di conforto
/// visivo, non un verdetto del catalogo.
@MainActor
final class ImportReviewViewModel: ObservableObject {

    struct Candidate: Identifiable, Equatable {
        let show: TVShow
        /// 0–99: somiglianza del titolo (più il bonus dell'anno, se l'export lo porta).
        let confidence: Int
        var id: Int { show.id }
    }

    let importViewModel: ImportViewModel

    @Published private(set) var items: [ImportReviewItem]
    @Published private(set) var candidates: [String: [Candidate]] = [:]
    @Published private(set) var loadingCandidates: Set<String> = []
    /// La serie TMDB scelta per ogni card (candidato toccato o ricerca manuale).
    @Published var selections: [String: TVShow] = [:]
    /// Le scelte arrivate dalla ricerca manuale: la card le etichetta come tali.
    @Published var manualPicks: Set<String> = []
    @Published var excluding: Set<String> = []
    @Published var submitting = false
    /// La card per cui è aperta la ricerca manuale.
    @Published var searchItem: ImportReviewItem?

    /// Il totale della sessione: il denominatore di "N di M rimasti" e della barra. Fermo
    /// all'apertura — se cala insieme al numeratore la barra non avanza mai.
    private(set) var sessionTotal: Int

    init(importViewModel: ImportViewModel = ImportStatusCenter.shared.importViewModel) {
        self.importViewModel = importViewModel
        let items: [ImportReviewItem]
        if case .done(let report) = importViewModel.state {
            items = report.reviewItems
        } else {
            items = []
        }
        self.items = items
        self.sessionTotal = max(items.count, 1)
    }

    /// Card ancora senza una decisione (né scelta né esclusione).
    var remaining: Int {
        items.filter { selections[$0.id] == nil }.count
    }

    var progressFraction: Double {
        guard sessionTotal > 0 else { return 1 }
        return Double(sessionTotal - remaining) / Double(sessionTotal)
    }

    var selectedResolutions: [ImportManualResolution] {
        // Dedup difensivo per id serie: il report raggruppa per titolo, quindi lo stesso
        // tvdb_series_id può comparire su due card (nomi diversi nell'export). Il server
        // rifiuta i duplicati sull'intero batch — meglio non dargliene mai.
        var visti = Set<String>()
        return items.compactMap { item -> ImportManualResolution? in
            guard case .series(let tvdbId) = item.source, let tvdbId,
                  let show = selections[item.id],
                  visti.insert(tvdbId).inserted else { return nil }
            return ImportManualResolution(tvdbSeriesId: tvdbId, tmdbShowId: show.id)
        }
    }

    // MARK: Candidati

    func loadCandidatesIfNeeded(for item: ImportReviewItem) async {
        guard item.isResolvable,
              candidates[item.id] == nil,
              !loadingCandidates.contains(item.id) else { return }
        loadingCandidates.insert(item.id)
        defer { loadingCandidates.remove(item.id) }

        let query = Self.cleanedQuery(from: item.titolo)
        guard !query.isEmpty else {
            candidates[item.id] = []
            return
        }
        do {
            let results = try await TMDBService.shared
                .searchTVShows(query: query, page: 1).results
            let scored = results
                .map { Candidate(show: $0,
                                 confidence: Self.confidence(source: item.titolo, show: $0)) }
                .sorted { $0.confidence > $1.confidence }
            candidates[item.id] = Array(scored.prefix(2))
        } catch {
            // Nessun candidato non è un errore bloccante: resta la ricerca manuale.
            candidates[item.id] = []
        }
    }

    func select(_ show: TVShow, for item: ImportReviewItem, manual: Bool = false) {
        selections[item.id] = show
        if manual { manualPicks.insert(item.id) } else { manualPicks.remove(item.id) }
    }

    func deselect(_ item: ImportReviewItem) {
        selections[item.id] = nil
        manualPicks.remove(item.id)
    }

    // MARK: Azioni

    func exclude(_ item: ImportReviewItem) async {
        guard !excluding.contains(item.id) else { return }
        excluding.insert(item.id)
        defer { excluding.remove(item.id) }
        let ok = await importViewModel.excludeItems([item])
        if ok {
            items.removeAll { $0.id == item.id }
            selections[item.id] = nil
            manualPicks.remove(item.id)
        }
    }

    /// Il batch unico di §7.4. `true` = job riaperto: la pagina si chiude e il banner della
    /// home mostra il progresso del mapping.
    func submit() async -> Bool {
        let resolutions = selectedResolutions
        guard !resolutions.isEmpty, !submitting else { return false }
        submitting = true
        defer { submitting = false }
        return await importViewModel.resolveManually(resolutions)
    }

    // MARK: Euristiche

    /// Il titolo dell'export ripulito per la ricerca: via l'anno tra parentesi e le code da
    /// nome-file ("S1-S3 COMPLETE"…) che affondano la query.
    static func cleanedQuery(from title: String) -> String {
        var text = title
        text = text.replacingOccurrences(of: #"\((19|20)\d{2}\)"#,
                                         with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?i)\bS\d{1,2}([ .-]?(S|E)\d{1,3})*\b.*$"#,
            with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?i)\b(complete|completa|season|stagione|ita|eng|sub|1080p|720p|x264|x265|web[- ]?dl)\b.*$"#,
            with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func confidence(source: String, show: TVShow) -> Int {
        let a = normalized(cleanedQuery(from: source))
        let b = normalized(show.name)
        guard !a.isEmpty, !b.isEmpty else { return 5 }
        var score = similarity(a, b)
        // Se l'export porta un anno tra parentesi e combacia con la messa in onda, è un
        // segnale forte — è esattamente il caso "Sherlock (2010)".
        if let sourceYear = yearInTitle(source),
           let showYear = show.firstAirDate?.prefix(4), sourceYear == String(showYear) {
            score = min(1, score + 0.2)
        }
        return max(5, min(99, Int((score * 100).rounded())))
    }

    private static func yearInTitle(_ title: String) -> String? {
        guard let range = title.range(of: #"\((19|20)\d{2}\)"#,
                                      options: .regularExpression) else { return nil }
        return String(title[range].dropFirst().dropLast())
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 0…1: Levenshtein normalizzata, con un bonus se uno dei due è prefisso dell'altro
    /// (i titoli romanizzati e le abbreviazioni — "Kizu" → "Kizumonogatari" — vivono lì).
    private static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.hasPrefix(b) || b.hasPrefix(a) {
            let ratio = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
            return 0.55 + 0.35 * ratio
        }
        let distance = levenshtein(Array(a), Array(b))
        let maxLength = max(a.count, b.count)
        guard maxLength > 0 else { return 0 }
        return max(0, 1 - Double(distance) / Double(maxLength))
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

// MARK: - Vista

/// La pagina del mockup: header con "N di M rimasti" e barra verde, card TV Time con i
/// candidati e la loro percentuale, "Cerca manualmente" / "Escludi", batch unico in fondo.
/// Raggiungibile dall'onboarding, dal banner "Gestisci" della home e dal profilo.
@MainActor
struct ImportReviewView: View {
    @StateObject private var viewModel: ImportReviewViewModel
    @Environment(\.dismiss) private var dismiss
    /// Chiamata quando il batch è partito o l'utente rimanda: l'onboarding la usa per
    /// proseguire con le tappe; in app non serve.
    var onFinished: (() -> Void)?
    /// La card da cui si arriva: la ricerca si apre già su quel titolo, invece di far
    /// ritrovare la riga in un elenco lungo.
    var focusItemId: String?

    init(viewModel: ImportReviewViewModel? = nil,
         focusItemId: String? = nil,
         onFinished: (() -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? ImportReviewViewModel())
        self.focusItemId = focusItemId
        self.onFinished = onFinished
    }

    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                ProgressView(value: viewModel.items.isEmpty ? 1 : viewModel.progressFraction)
                    .progressViewStyle(.linear)
                    .tint(.green)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                if viewModel.items.isEmpty {
                    allResolvedView
                } else {
                    itemsList
                }
            }
        }
        .sheet(item: $viewModel.searchItem) { item in
            ImportReviewSearchSheet(item: item, viewModel: viewModel)
        }
        .task {
            guard let focusItemId,
                  let item = viewModel.items.first(where: { $0.id == focusItemId })
            else { return }
            viewModel.searchItem = item
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            BackCircleButton { dismiss() }
            VStack(alignment: .leading, spacing: 2) {
                Text("import.review.title".localized)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                Text(viewModel.items.isEmpty
                     ? "import.review.allResolved".localized
                     : String(format: "import.review.remaining".localized,
                              viewModel.remaining, viewModel.sessionTotal))
                    .font(.system(size: 13))
                    .foregroundColor(.theme.textSecondary)
            }
            Spacer()
        }
    }

    // MARK: Lista

    private var itemsList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    Text("import.review.intro".localized)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 14)

                    ForEach(viewModel.items) { item in
                        ImportReviewCard(item: item, viewModel: viewModel)
                            .task { await viewModel.loadCandidatesIfNeeded(for: item) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            bottomBar
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if let errore = viewModel.importViewModel.manualResolveError {
                Text("import.resolve.failed".localized + " " + errore)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            let count = viewModel.selectedResolutions.count
            if count > 0 {
                PrimaryButton(title: count == 1
                                ? "import.review.importOne".localized
                                : String(format: "import.review.importCount".localized, count),
                              isLoading: viewModel.submitting) {
                    Task {
                        if await viewModel.submit() {
                            dismiss()
                            onFinished?()
                        }
                    }
                }
                .padding(.horizontal, 20)
            }

            Button {
                dismiss()
                onFinished?()
            } label: {
                Text("import.review.later".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.theme.textSecondary)
            }
            .padding(.bottom, 14)
        }
        .padding(.top, 10)
        .background(Color.theme.background)
    }

    // MARK: Tutto risolto

    private var allResolvedView: some View {
        VStack(spacing: 0) {
            Spacer()
            Circle()
                .fill(Color.green.opacity(0.1))
                .frame(width: 110, height: 110)
                .overlay(Circle().stroke(Color.green.opacity(0.35), lineWidth: 1))
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundColor(.green)
                )
                .padding(.bottom, 26)

            Text("import.review.libraryOk".localized)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .padding(.bottom, 10)

            Text("import.review.libraryOk.subtitle".localized)
                .font(.system(size: 15))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
                .padding(.bottom, 26)

            Button {
                dismiss()
                onFinished?()
            } label: {
                Text("common.close".localized)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Color.theme.background)
                    .padding(.horizontal, 40)
                    .frame(height: 52)
                    .background(Color.theme.accentOrange)
                    .clipShape(Capsule())
            }
            Spacer()
            Spacer()
        }
    }
}

// MARK: - Card

private struct ImportReviewCard: View {
    let item: ImportReviewItem
    @ObservedObject var viewModel: ImportReviewViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ImportSourceBadge()
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.titolo)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                        .lineLimit(2)
                    Text(sourceMeta)
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                }
                Spacer(minLength: 0)
            }

            if item.isResolvable {
                candidatesSection
            } else if item.isMovie {
                Text("import.review.movieHint".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.theme.textSecondary)
            }

            HStack(spacing: 10) {
                if item.isResolvable {
                    Button {
                        viewModel.searchItem = item
                    } label: {
                        Text("import.review.searchManually".localized)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.theme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 14)
                                .fill(Color.white.opacity(0.07)))
                    }
                }
                Button {
                    Task { await viewModel.exclude(item) }
                } label: {
                    Group {
                        if viewModel.excluding.contains(item.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("import.review.exclude".localized)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.theme.textSecondary)
                        }
                    }
                    .frame(maxWidth: item.isResolvable ? 110 : .infinity)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.05)))
                }
                .disabled(viewModel.excluding.contains(item.id))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    private var sourceMeta: String {
        var parts = ["TV Time"]
        if item.episodi > 0 {
            parts.append(String(format: "import.review.episodesSeen".localized, item.episodi))
        }
        parts.append(ImportReviewReason.label(for: item.motivo))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var candidatesSection: some View {
        let candidates = viewModel.candidates[item.id]
        if viewModel.loadingCandidates.contains(item.id) && candidates == nil {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .frame(height: 56)
        } else if let candidates {
            VStack(spacing: 10) {
                // La scelta manuale compare come candidato in testa, marcata.
                if let chosen = viewModel.selections[item.id],
                   viewModel.manualPicks.contains(item.id) {
                    CandidateRow(show: chosen, confidence: nil,
                                 subtitleOverride: "import.review.manualPick".localized,
                                 isSelected: true) {
                        viewModel.deselect(item)
                    }
                }
                ForEach(candidates) { candidate in
                    let isSelected = viewModel.selections[item.id]?.id == candidate.show.id
                        && !viewModel.manualPicks.contains(item.id)
                    CandidateRow(show: candidate.show, confidence: candidate.confidence,
                                 subtitleOverride: nil, isSelected: isSelected) {
                        if isSelected {
                            viewModel.deselect(item)
                        } else {
                            viewModel.select(candidate.show, for: item)
                        }
                    }
                }
                if candidates.isEmpty && viewModel.selections[item.id] == nil {
                    Text("import.review.noCandidates".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Riga candidato

/// La card del possibile match: poster, titolo, anno, percentuale. È la stessa resa dentro
/// la ricerca manuale — l'utente deve riconoscere visivamente ciò che sta abbinando.
private struct CandidateRow: View {
    let show: TVShow
    let confidence: Int?
    let subtitleOverride: String?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                CachedAsyncImage(url: show.posterURL, maxPixelSize: 120) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08))
                }
                .frame(width: 42, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(show.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitleOverride ?? subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let confidence {
                    Text("\(confidence)%")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(confidence >= 80 ? .green : .theme.accentOrange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(
                            (confidence >= 80 ? Color.green : Color.theme.accentOrange)
                                .opacity(0.12)))
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.theme.accentOrange)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.theme.accentOrange.opacity(0.08)
                                     : Color.white.opacity(0.03))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(isSelected ? Color.theme.accentOrange.opacity(0.7)
                                           : Color.white.opacity(0.08), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let year = show.firstAirDate?.prefix(4), !year.isEmpty {
            parts.append(String(year))
        }
        if let seasons = show.numberOfSeasons, seasons > 0 {
            parts.append(String(format: "import.review.seasons".localized, seasons))
        }
        if parts.isEmpty { parts.append("TV") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Ricerca manuale

/// La ricerca manuale con la card della sorgente SEMPRE in testa: senza, a metà lista non
/// si ricorda più QUALE titolo dell'archivio si sta abbinando.
@MainActor
private struct ImportReviewSearchSheet: View {
    let item: ImportReviewItem
    @ObservedObject var viewModel: ImportReviewViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var results: [TVShow] = []
    @State private var searching = false
    @State private var searchFailed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.theme.background.ignoresSafeArea()
                VStack(spacing: 12) {
                    // La card sorgente: il titolo che stai cercando, con episodi e motivo.
                    HStack(spacing: 12) {
                        ImportSourceBadge()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.titolo)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.theme.textPrimary)
                                .lineLimit(2)
                            Text(sourceMeta)
                                .font(.system(size: 12))
                                .foregroundColor(.theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(hex: "f5c518").opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 16)
                                .stroke(Color(hex: "f5c518").opacity(0.35), lineWidth: 1))
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                    TextField("import.resolve.searchPlaceholder".localized, text: $query)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 16)
                        .onSubmit { Task { await search() } }
                        // Ricerca LIVE mentre si scrive, come in SearchView: il task si
                        // riavvia a ogni carattere e il sonno iniziale fa da debounce —
                        // una richiesta ogni pausa di battitura, non una per tasto.
                        .task(id: query) {
                            guard !query.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty else { return }
                            try? await Task.sleep(for: .milliseconds(350))
                            guard !Task.isCancelled else { return }
                            await search()
                        }

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
                        ScrollView {
                            VStack(spacing: 10) {
                                ForEach(results) { show in
                                    CandidateRow(
                                        show: show,
                                        confidence: ImportReviewViewModel
                                            .confidence(source: item.titolo, show: show),
                                        subtitleOverride: nil,
                                        isSelected: viewModel.selections[item.id]?.id == show.id
                                    ) {
                                        viewModel.select(show, for: item, manual: true)
                                        dismiss()
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
            .navigationTitle("import.review.searchManually".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
        }
        .task {
            // Il testo iniziale è il titolo ripulito: a valorizzarlo ci pensa il task
            // con id `query` qui sopra, che parte da solo — niente doppia ricerca.
            query = ImportReviewViewModel.cleanedQuery(from: item.titolo)
        }
    }

    private var sourceMeta: String {
        var parts = ["TV Time"]
        if item.episodi > 0 {
            parts.append(String(format: "import.review.episodesSeen".localized, item.episodi))
        }
        parts.append(ImportReviewReason.label(for: item.motivo))
        return parts.joined(separator: " · ")
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searching = true
        searchFailed = false
        do {
            results = try await TMDBService.shared.searchTVShows(query: text, page: 1).results
        } catch {
            results = []
            searchFailed = true
        }
        searching = false
    }
}

// MARK: - Pezzi condivisi

/// La tessera gialla "tv:t" della sorgente TV Time (la gemella di quella dell'onboarding,
/// che è privata di quel file).
struct ImportSourceBadge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(hex: "f5c518"))
            .frame(width: 44, height: 44)
            .overlay(
                Text("tv:t")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(.black)
            )
    }
}

/// I motivi tecnici della pipeline → una frase che l'utente possa leggere. Il motivo grezzo
/// non si butta: cade nel caso `generic`, che lo mostra com'è (§7.4: non si abbellisce).
enum ImportReviewReason {
    static func label(for motivo: String) -> String {
        let lower = motivo.lowercased()
        if lower.contains("conflitto") {
            return "import.review.reason.conflict".localized
        }
        if lower.contains("not_found") || lower.contains("assente") {
            return "import.review.reason.notFound".localized
        }
        if lower.contains("ambiguous") {
            return "import.review.reason.ambiguous".localized
        }
        if lower.contains("anno") || lower.contains("no_year") {
            return "import.review.reason.yearMissing".localized
        }
        if lower.contains("id serie") {
            return "import.review.reason.missingId".localized
        }
        return motivo
    }
}
