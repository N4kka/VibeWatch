import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// SPEC v3 §7 — "Import from". Oggi una sorgente sola, TV Time (.zip), ma la schermata è una
/// lista apposta: gli import futuri sono righe nuove, non schermate nuove.
///
/// La vista è un oblò sul job (§7.2: lo stato vive sul server, le fasi le muove il cron):
/// l'unico tratto che richiede l'app aperta è l'upload. Appena il job esiste lo si dice
/// esplicitamente — "puoi chiudere l'app" — perché è la promessa della spec, non un dettaglio.
@MainActor
struct ImportView: View {
    /// Redesign 2.0: l'oblò CONDIVISO di tutta l'app (banner in home compreso). Osservato e
    /// non posseduto: il polling deve sopravvivere alla chiusura di questa schermata.
    @ObservedObject private var viewModel: ImportViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var showReview = false
    /// La card da cui si è entrati nell'inbox: la ricerca si apre già su quel titolo.
    @State private var reviewFocusId: String?
    /// La ricerca dell'app per i titoli che l'inbox non può risolvere (film ed esclusi).
    @State private var showManualSearch = false
    @State private var manualSearchQuery = ""
    @StateObject private var manualSearchViewModel = SearchViewModel()

    init(viewModel: ImportViewModel? = nil) {
        self.viewModel = viewModel ?? ImportStatusCenter.shared.importViewModel
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle(isReport ? "" : "import.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(isReport)
            .toolbar {
                if !isReport {
                    ToolbarItem(placement: .topBarLeading) {
                        BackCircleButton { dismiss() }
                    }
                }
            }
            .task {
                AnalyticsService.shared.logScreenView(screenName: "Import")
                await viewModel.loadExisting()
            }
            .fileImporter(isPresented: $showPicker,
                          allowedContentTypes: [.zip]) { result in
                if case .success(let url) = result {
                    Task { await viewModel.importFile(at: url) }
                }
                // Il picker annullato non è un errore: si resta sulle sorgenti.
            }
            .fullScreenCover(isPresented: $showReview) {
                ImportReviewView(focusItemId: reviewFocusId)
                    .onDisappear { reviewFocusId = nil }
            }
            // Il report resta sotto: chiudendo la ricerca ci si ritrova dov'eravamo.
            .sheet(isPresented: $showManualSearch) {
                SearchView(viewModel: manualSearchViewModel)
                    .onAppear {
                        manualSearchViewModel.searchQuery = manualSearchQuery
                        manualSearchViewModel.search()
                    }
            }
        }
    }

    /// Nello stato di report l'intestazione è quella della pagina (titolo grande + sorgente e
    /// periodo): la barra di sistema sopra sarebbe un secondo titolo.
    private var isReport: Bool {
        if case .done = viewModel.state { return true }
        return false
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

    /// Il report di fine import, ridisegnato.
    ///
    /// Prima era un muro di frasi: una riga di testo per ogni numero, tutte uguali, tutte
    /// centrate, senza gerarchia — e in fondo l'elenco di ciò che era rimasto fuori. Qui c'è un
    /// esito (la fascia verde), tre numeri grandi, ciò che è rimasto fuori come card toccabili,
    /// e il resto in una tabella di dettagli con le spiegazioni in chiaro. Niente è sparito:
    /// §7.4 vieta di abbellire, non di ordinare.
    private func reportView(_ report: ImportReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                reportHeader(report)

                if report.serieImportate > 0 || report.episodiImportati > 0 {
                    successBanner(report)
                }

                reportTiles(report)

                let leftOut = report.leftOutItems
                if !leftOut.isEmpty {
                    leftOutSection(leftOut)
                } else {
                    Text("import.report.allResolved".localized)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }

                detailsSection(report)
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        // La CTA sta fuori dallo scroll: "Fatto" non deve essere una cosa da cercare in fondo.
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: "common.done".localized) { dismiss() }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(
                    LinearGradient(
                        colors: [Color.theme.background.opacity(0), Color.theme.background],
                        startPoint: .top, endPoint: .bottom
                    )
                    .ignoresSafeArea()
                )
        }
    }

    private func reportHeader(_ report: ImportReport) -> some View {
        HStack(spacing: 14) {
            BackCircleButton { dismiss() }
            VStack(alignment: .leading, spacing: 2) {
                Text("import.report.title".localized)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                Text(sourceAndPeriod(report))
                    .font(.system(size: 13))
                    .foregroundColor(.theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// "TV Time · set 2015 – lug 2026". Senza le date resta la sola sorgente.
    private func sourceAndPeriod(_ report: ImportReport) -> String {
        let sorgente = "import.source.tvtime".localized
        guard let dal = report.dal.flatMap(Self.monthYear),
              let al = report.al.flatMap(Self.monthYear) else { return sorgente }
        return String(format: "import.report.sourcePeriod".localized, sorgente, dal, al)
    }

    // MARK: Esito

    private func successBanner(_ report: ImportReport) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark")
                .font(.system(size: 17, weight: .heavy))
                .foregroundColor(.green)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color.green.opacity(0.16)))

            VStack(alignment: .leading, spacing: 4) {
                Text("import.report.success.title".localized)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                Text(successSubtitle(report))
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.green.opacity(0.07)))
        .overlay(
            RoundedRectangle(cornerRadius: 18).stroke(Color.green.opacity(0.35), lineWidth: 1)
        )
    }

    /// I voti si nominano solo quando sono passati davvero: su un job vecchio la frase
    /// prometterebbe qualcosa che non c'è.
    private func successSubtitle(_ report: ImportReport) -> String {
        let chiave = report.votiImportati && report.votiStelleImportati > 0
            ? "import.report.success.subtitleWithRatings"
            : "import.report.success.subtitle"
        return String(format: chiave.localized, report.serieImportate, filmTotali(report))
    }

    private func filmTotali(_ report: ImportReport) -> Int {
        report.filmSupportati ? report.filmImportati + report.filmWatchlistImportati : 0
    }

    // MARK: Numeri

    private func reportTiles(_ report: ImportReport) -> some View {
        HStack(spacing: 12) {
            reportTile(report.episodiImportati, key: "import.report.tile.episodes")
            reportTile(report.serieImportate, key: "import.report.shows")
            if report.filmSupportati {
                reportTile(filmTotali(report), key: "import.report.tile.movies")
            }
        }
    }

    private func reportTile(_ value: Int, key: String) -> some View {
        VStack(spacing: 4) {
            Text(value.formatted())
                .font(.system(size: 26, weight: .heavy))
                .foregroundColor(.theme.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(key.localized)
                .font(.system(size: 13))
                .foregroundColor(.theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: Rimasti fuori

    private func leftOutSection(_ items: [ImportReviewItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("import.report.leftOut.title".localized)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                Text("\(items.count)")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(.theme.accentOrange)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.theme.accentOrange.opacity(0.16)))
            }

            Text("import.report.leftOut.subtitle".localized)
                .font(.system(size: 14))
                .foregroundColor(.theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(items) { item in
                leftOutCard(item)
            }

            Button {
                copyLeftOut(items)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                    Text("import.report.copyList".localized)
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.theme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(RoundedRectangle(cornerRadius: 15).fill(Color.white.opacity(0.05)))
                .overlay(
                    RoundedRectangle(cornerRadius: 15)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func leftOutCard(_ item: ImportReviewItem) -> some View {
        Button {
            open(item)
        } label: {
            HStack(spacing: 14) {
                // Questi titoli non hanno un id del catalogo: una copertina non esiste per
                // definizione. L'iniziale su fondo tinto è un segnaposto, non un poster finto.
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Self.placeholderGradient(for: item.titolo))
                    Text(Self.initial(of: item.titolo))
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(.white.opacity(0.35))
                }
                .frame(width: 56, height: 80)

                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.displayTitle(item.titolo))
                        .font(.system(size: 16.5, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        Text((item.isMovie ? "common.movie" : "common.tvShow").localized)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.theme.textSecondary)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(Capsule().fill(Color.white.opacity(0.08)))

                        Text(leftOutMeta(item))
                            .font(.system(size: 13.5))
                            .foregroundColor(.theme.textSecondary)
                            .lineLimit(1)
                    }

                    Text(item.escluso
                         ? "import.report.leftOut.excluded".localized
                         : ImportReviewReason.label(for: item.motivo))
                        .font(.system(size: 13.5))
                        .foregroundColor(.theme.textSecondary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 6)

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.theme.accentOrange)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.theme.accentOrange.opacity(0.14)))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 17).fill(Color.white.opacity(0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 17).stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// La riga meta: anno e data di visione ci sono solo per i film (l'export delle serie non
    /// porta l'anno), gli episodi visti solo per le serie.
    private func leftOutMeta(_ item: ImportReviewItem) -> String {
        var parts: [String] = []
        if let anno = item.anno, !anno.isEmpty { parts.append(anno) }
        if item.episodi > 0 {
            parts.append(String(format: "import.report.leftOut.episodes".localized, item.episodi))
        }
        if let visto = item.vistoIl.flatMap(Self.dayMonthYear) {
            parts.append(String(format: "import.report.leftOut.seenOn".localized, visto))
        }
        return parts.joined(separator: " · ")
    }

    /// Un titolo che l'import non ha saputo collocare si cerca a mano: le serie ancora
    /// risolvibili passano dall'inbox (che sa riaprire il job), tutto il resto — film ed
    /// esclusi — dalla ricerca dell'app, con il titolo già scritto.
    private func open(_ item: ImportReviewItem) {
        if item.isResolvable {
            reviewFocusId = item.id
            showReview = true
        } else {
            manualSearchQuery = ImportReviewViewModel.cleanedQuery(from: item.titolo)
            showManualSearch = true
        }
    }

    /// Certe righe dell'export non hanno nemmeno il nome della serie (campo vuoto, non nullo).
    /// Dirlo è meglio di una card muta: il titolo manca, gli episodi contati no.
    private static func displayTitle(_ titolo: String) -> String {
        let pulito = titolo.trimmingCharacters(in: .whitespacesAndNewlines)
        return pulito.isEmpty ? "import.report.leftOut.untitled".localized : pulito
    }

    private static func initial(of titolo: String) -> String {
        let pulito = titolo.trimmingCharacters(in: .whitespacesAndNewlines)
        return pulito.isEmpty ? "?" : pulito.prefix(1).uppercased()
    }

    private func copyLeftOut(_ items: [ImportReviewItem]) {
        let righe = items.map { item -> String in
            let motivo = item.escluso
                ? "import.report.leftOut.excluded".localized
                : ImportReviewReason.label(for: item.motivo)
            return "\(Self.displayTitle(item.titolo)) — \(motivo)"
        }
        UIPasteboard.general.string = righe.joined(separator: "\n")
        ToastCenter.shared.show(success: "import.report.copied".localized)
    }

    private static func placeholderGradient(for title: String) -> LinearGradient {
        let tinte: [Color] = [
            Color(hex: "5a2230"), Color(hex: "20344d"), Color(hex: "5a3a18"),
            Color(hex: "4a4520"), Color(hex: "2f2450")
        ]
        let indice = abs(title.hashValue) % tinte.count
        return LinearGradient(colors: [tinte[indice], tinte[indice].opacity(0.45)],
                              startPoint: .top, endPoint: .bottom)
    }

    // MARK: Dettagli

    private func detailsSection(_ report: ImportReport) -> some View {
        let rows = detailRows(report)
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("import.report.details".localized)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.theme.textPrimary)

                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 {
                                Divider().overlay(Color.white.opacity(0.07))
                            }
                            detailRow(row)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 17).fill(Color.white.opacity(0.05)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 17)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    )
                }
            }
        }
    }

    private struct DetailRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let value: String
        /// I numeri che dicono una perdita si vedono da lontano.
        let isCritical: Bool
    }

    private func detailRow(_ row: DetailRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13.5))
                        .foregroundColor(.theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 12)
            Text(row.value)
                .font(.system(size: 17, weight: .heavy))
                .foregroundColor(row.isCritical ? .theme.accentOrange : .theme.textPrimary)
        }
        .padding(14)
    }

    /// Ogni riga esiste solo se ha qualcosa da dire: uno zero muto è indistinguibile da
    /// "non ne avevi", e §7.4 non ammette numeri finti.
    private func detailRows(_ report: ImportReport) -> [DetailRow] {
        var rows: [DetailRow] = []

        if let dal = report.dal.flatMap(Self.dayMonthYear),
           let al = report.al.flatMap(Self.dayMonthYear) {
            rows.append(DetailRow(
                id: "period",
                title: "import.report.detail.period".localized,
                subtitle: String(format: "import.report.period".localized, dal, al),
                value: Self.spanLabel(from: report.dal, to: report.al),
                isCritical: false))
        }

        if report.statiSupportati && report.statiSerieImportati > 0 {
            rows.append(DetailRow(
                id: "statuses",
                title: "import.report.detail.statuses".localized,
                subtitle: "import.report.detail.statuses.hint".localized,
                value: "\(report.statiSerieImportati)",
                isCritical: false))
        }

        if report.votiImportati && report.votiStelleImportati > 0 {
            rows.append(DetailRow(
                id: "ratings",
                title: "import.report.detail.ratings".localized,
                subtitle: nil,
                value: "\(report.votiStelleImportati)",
                isCritical: false))
        }

        if report.favoritesSupportati && report.favoritesImportati > 0 {
            rows.append(DetailRow(
                id: "favorites",
                title: "import.report.detail.favorites".localized,
                subtitle: nil,
                value: "\(report.favoritesImportati)",
                isCritical: false))
        }

        if report.filmSupportati && report.filmImportati > 0 {
            rows.append(DetailRow(
                id: "moviesSeen",
                title: "import.report.detail.moviesSeen".localized,
                subtitle: nil,
                value: "\(report.filmImportati)",
                isCritical: false))
        }

        if report.filmSupportati && report.filmWatchlistImportati > 0 {
            rows.append(DetailRow(
                id: "moviesWatchlist",
                title: "import.report.detail.moviesWatchlist".localized,
                subtitle: nil,
                value: "\(report.filmWatchlistImportati)",
                isCritical: false))
        }

        if report.votiImportati && report.votiStelleNonRisolti > 0 {
            rows.append(DetailRow(
                id: "ratingsUnmatched",
                title: "import.report.detail.ratingsUnmatched".localized,
                subtitle: "import.report.detail.ratingsUnmatched.hint".localized,
                value: "\(report.votiStelleNonRisolti)",
                isCritical: true))
        }

        if !report.votiImportati && report.votiStelle + report.votiReaction > 0 {
            rows.append(DetailRow(
                id: "ratingsDeferred",
                title: "import.report.detail.ratingsDeferred".localized,
                subtitle: nil,
                value: "\(report.votiStelle + report.votiReaction)",
                isCritical: true))
        }

        if report.statiSupportati && report.statiSerieNonRisolti > 0 {
            rows.append(DetailRow(
                id: "statusesUnresolved",
                title: "import.report.detail.statusesUnresolved".localized,
                subtitle: nil,
                value: "\(report.statiSerieNonRisolti)",
                isCritical: true))
        }

        if report.episodiFuoriStruttura > 0 {
            rows.append(DetailRow(
                id: "outOfStructure",
                title: "import.report.detail.outOfStructure".localized,
                subtitle: "import.report.detail.outOfStructure.hint".localized,
                value: "\(report.episodiFuoriStruttura)",
                isCritical: true))
        }

        if report.favoritesSupportati && report.favoriteFilmNonSupportati > 0 {
            rows.append(DetailRow(
                id: "favoriteMovies",
                title: "import.report.detail.favoriteMovies".localized,
                subtitle: nil,
                value: "\(report.favoriteFilmNonSupportati)",
                isCritical: true))
        }

        return rows
    }

    // MARK: Date

    /// Le date del report sono timestamp del server ("2015-09-24 18:00:00"): qui contano
    /// solo giorno, mese e anno, scritti nella lingua dell'utente.
    private static func parse(_ iso: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(iso.prefix(10)))
    }

    private static func formatted(_ iso: String, template: String) -> String? {
        guard let date = parse(iso) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private static func monthYear(_ iso: String) -> String? { formatted(iso, template: "MMM y") }
    private static func dayMonthYear(_ iso: String) -> String? { formatted(iso, template: "d MMM y") }

    /// La distanza fra la prima e l'ultima visione, in anni. Sotto l'anno si dice così
    /// invece di arrotondare a "1 anno", che sarebbe un numero inventato.
    private static func spanLabel(from: String?, to: String?) -> String {
        guard let from, let to, let inizio = parse(from), let fine = parse(to) else { return "—" }
        let anni = Calendar.current.dateComponents([.year], from: inizio, to: fine).year ?? 0
        if anni >= 2 { return String(format: "import.report.detail.years".localized, anni) }
        if anni == 1 { return "import.report.detail.oneYear".localized }
        return "import.report.detail.lessThanYear".localized
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

