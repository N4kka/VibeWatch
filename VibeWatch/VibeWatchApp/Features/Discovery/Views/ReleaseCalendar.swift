import SwiftUI
import Combine

// MARK: - ViewModel

/// Redesign 2.0 — le uscite e il "continua a guardare" in testa a Scopri.
///
/// Legge la STESSA cache locale del Tracking (`tv_tracking` + `tv_timeline`, §13.6): zero rete,
/// zero calcoli nel client — i bucket e la timeline li decide il server. Scopri non ha il budget
/// dei 300 ms, ma la ragione per non aggiungere una seconda sorgente è un'altra: due sorgenti
/// per lo stesso dato sono il "due posti, due numeri" già pagato con le stats.
@MainActor
final class DiscoveryTrackingHighlightsViewModel: ObservableObject {
    /// Tutte le uscite dei prossimi 30 giorni, piatte e ordinate per data.
    @Published private(set) var upcoming: [TimelineEntry] = []
    /// Le serie con un episodio pronto da vedere (bucket `up_next`, ordinate dal server).
    @Published private(set) var continueWatching: [TrackingRow] = []

    private let repository: any TrackingRepositoryProtocol
    private var cancellables = Set<AnyCancellable>()

    init(repository: any TrackingRepositoryProtocol = LocalTrackingRepository.shared) {
        self.repository = repository

        NotificationCenter.default.publisher(for: .syncEngineCompleted)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.load() } }
            .store(in: &cancellables)
    }

    func load() async {
        do {
            let sections = try await repository.fetchSections()
            upcoming = sections.timeline.flatMap(\.entries).sorted { $0.airDate < $1.airDate }
            continueWatching = sections.sections.first { $0.bucket == .upNext }?.rows ?? []
        } catch {
            // Le sezioni in Scopri sono un di più: se la lettura fallisce si tengono i dati
            // precedenti e si logga. La schermata che DEVE dichiarare l'errore è il Tracking.
            Logger.error("[Discovery] lettura tracking highlights fallita: \(error.localizedDescription)")
        }
    }

    /// Le uscite raggruppate per giorno di calendario (mezzanotte locale).
    var releasesByDay: [Date: [TimelineEntry]] {
        Dictionary(grouping: upcoming) { Calendar.current.startOfDay(for: $0.airDate) }
    }
}

// MARK: - Strip dei 7 giorni

/// La strip "In uscita": 7 giorni da oggi, mini-poster e conteggio, tap → calendario mensile.
struct ReleaseStripSection: View {
    @ObservedObject var viewModel: DiscoveryTrackingHighlightsViewModel
    /// Apre il calendario sul giorno toccato (`nil` = oggi, dal link del mese).
    let onOpenCalendar: (Date?) -> Void

    private var calendar: Calendar { .current }

    private var days: [Date] {
        let today = calendar.startOfDay(for: Date())
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: LocalizationManager.shared.currentLanguage.id)
        formatter.dateFormat = "MMMM"
        return formatter.string(from: Date()).capitalized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline) {
                Text("discovery.upcoming".localized)
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundColor(.theme.textPrimary)
                Spacer()
                Button { onOpenCalendar(nil) } label: {
                    HStack(spacing: 5) {
                        Text(monthTitle)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.theme.accentOrange)
                }
            }
            .padding(.horizontal, 20)

            HStack(spacing: 6) {
                ForEach(days, id: \.self) { day in
                    dayCell(day)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = calendar.isDateInToday(day)
        let releases = viewModel.releasesByDay[day] ?? []

        return Button { onOpenCalendar(day) } label: {
            VStack(spacing: 6) {
                Text(dowLabel(day, isToday: isToday))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isToday ? .theme.accentOrange : .theme.textSecondary)
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.theme.textPrimary)

                if let first = releases.first {
                    miniPoster(first, count: releases.count)
                } else {
                    // Il giorno vuoto si disegna vuoto: una strip che mostra solo i giorni
                    // pieni sembrerebbe un elenco, e non risponderebbe a "domani esce qualcosa?"
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3]))
                        .frame(width: 22, height: 30)
                        .overlay {
                            Text("–")
                                .font(.system(size: 12))
                                .foregroundColor(Color.white.opacity(0.25))
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(isToday ? Color.theme.accentOrange.opacity(0.13) : Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isToday ? Color.theme.accentOrange.opacity(0.55) : Color.white.opacity(0.07), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func dowLabel(_ day: Date, isToday: Bool) -> String {
        if isToday { return "discovery.strip.today".localized }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: LocalizationManager.shared.currentLanguage.id)
        formatter.dateFormat = "EEE"
        return formatter.string(from: day).replacingOccurrences(of: ".", with: "").capitalized
    }

    private func miniPoster(_ entry: TimelineEntry, count: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let path = entry.posterPath,
                   let url = URL(string: "https://image.tmdb.org/t/p/w92\(path)") {
                    CachedAsyncImage(url: url, maxPixelSize: 100) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color.white.opacity(0.1))
                    }
                } else {
                    Rectangle().fill(Color.white.opacity(0.1))
                }
            }
            .frame(width: 22, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            Text("\(count)")
                .font(.system(size: 10, weight: .heavy))
                .foregroundColor(.theme.background)
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(Color.theme.accentOrange)
                .clipShape(Capsule())
                .offset(x: 7, y: -6)
        }
    }
}

// MARK: - Calendario mensile

/// Il calendario delle uscite: griglia del mese, badge coi conteggi, elenco del giorno scelto.
///
/// La finestra dei dati è quella di `tv_timeline`: i prossimi 30 giorni. I giorni fuori
/// finestra si disegnano spenti — un giorno senza badge fuori finestra significa "non lo so
/// ancora", non "nessuna uscita", e spegnerlo è il modo onesto di dirlo.
struct ReleaseCalendarView: View {
    @ObservedObject var viewModel: DiscoveryTrackingHighlightsViewModel
    let initialDay: Date?
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDay: Date
    @State private var monthAnchor: Date

    private var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2 // lunedì, come la strip del prototipo
        return c
    }

    init(viewModel: DiscoveryTrackingHighlightsViewModel, initialDay: Date? = nil) {
        self.viewModel = viewModel
        self.initialDay = initialDay
        let day = Calendar.current.startOfDay(for: initialDay ?? Date())
        _selectedDay = State(initialValue: day)
        _monthAnchor = State(initialValue: day)
    }

    private var locale: Locale { Locale(identifier: LocalizationManager.shared.currentLanguage.id) }

    /// Primo e ultimo giorno della finestra dati (oggi → oggi+30).
    private var windowStart: Date { calendar.startOfDay(for: Date()) }
    private var windowEnd: Date { calendar.date(byAdding: .day, value: 30, to: windowStart) ?? windowStart }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    weekdayHeader
                    monthGrid
                    selectedDayHeader
                    selectedDayList
                }
                .padding(.bottom, 40)
            }
            .background(Color.theme.background.ignoresSafeArea())
            .navigationDestination(for: Int.self) { showId in
                TVShowDetailView(tvShowId: showId)
            }
            // Autosufficiente: quando lo sheet arriva dal Tracking il ViewModel è vergine, e
            // caricarlo qui (non alla comparsa della tab) tiene il costo fuori da §13.6.
            .task { await viewModel.load() }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("discovery.releases.title".localized)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(.theme.textPrimary)
                Text(monthYearTitle)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.theme.accentOrange)
            }

            Spacer()

            HStack(spacing: 8) {
                monthArrow(systemName: "chevron.left", enabled: canGoPreviousMonth) {
                    shiftMonth(-1)
                }
                monthArrow(systemName: "chevron.right", enabled: canGoNextMonth) {
                    shiftMonth(1)
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .accessibilityLabel(Text("common.close".localized))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    private func monthArrow(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(enabled ? .theme.textPrimary : Color.white.opacity(0.2))
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.06))
                .clipShape(Circle())
        }
        .disabled(!enabled)
    }

    private var monthYearTitle: String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: monthAnchor).capitalized
    }

    private var canGoPreviousMonth: Bool {
        !calendar.isDate(monthAnchor, equalTo: windowStart, toGranularity: .month)
    }

    private var canGoNextMonth: Bool {
        !calendar.isDate(monthAnchor, equalTo: windowEnd, toGranularity: .month)
    }

    private func shiftMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: monthAnchor) {
            monthAnchor = next
        }
    }

    private var weekdayHeader: some View {
        let symbols = weekdaySymbols
        return HStack(spacing: 6) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 10.5, weight: .heavy))
                    .foregroundColor(Color.white.opacity(0.35))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var weekdaySymbols: [String] {
        let formatter = DateFormatter()
        formatter.locale = locale
        // `veryShortWeekdaySymbols` parte da domenica: si ruota per partire dal lunedì.
        let symbols = formatter.veryShortWeekdaySymbols ?? ["M", "T", "W", "T", "F", "S", "S"]
        return Array(symbols[1...] + symbols[..<1]).map { $0.uppercased() }
    }

    private var monthGrid: some View {
        let cells = buildCells()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(cells) { cell in
                monthCell(cell)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private struct DayCell: Identifiable {
        let id: Int
        let day: Date?          // nil = casella vuota prima del giorno 1
        let inWindow: Bool
        let count: Int
    }

    private func buildCells() -> [DayCell] {
        guard let monthRange = calendar.range(of: .day, in: .month, for: monthAnchor),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthAnchor))
        else { return [] }

        // Quante caselle vuote prima del giorno 1 (settimana che parte di lunedì).
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let leading = (weekday - calendar.firstWeekday + 7) % 7

        var cells: [DayCell] = (0..<leading).map { DayCell(id: -$0 - 1, day: nil, inWindow: false, count: 0) }
        let byDay = viewModel.releasesByDay

        for dayNumber in monthRange {
            guard let day = calendar.date(byAdding: .day, value: dayNumber - 1, to: firstOfMonth) else { continue }
            let inWindow = day >= windowStart && day <= windowEnd
            cells.append(DayCell(
                id: dayNumber,
                day: day,
                inWindow: inWindow,
                count: byDay[calendar.startOfDay(for: day)]?.count ?? 0
            ))
        }
        return cells
    }

    @ViewBuilder
    private func monthCell(_ cell: DayCell) -> some View {
        if let day = cell.day {
            let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
            Button { selectedDay = calendar.startOfDay(for: day) } label: {
                VStack(spacing: 3) {
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundColor(
                            isSelected ? .theme.background
                                : cell.inWindow ? .theme.textPrimary : Color.white.opacity(0.25)
                        )
                    if cell.count > 0 {
                        Text("\(cell.count)")
                            .font(.system(size: 9.5, weight: .heavy))
                            .foregroundColor(isSelected ? .theme.accentOrange : .theme.accentOrange)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(isSelected ? Color.theme.background : Color.theme.accentOrange.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(isSelected ? Color.theme.accentOrange : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12).stroke(
                        isSelected ? Color.theme.accentOrange
                            : cell.count > 0 ? Color.theme.accentOrange.opacity(0.35) : Color.white.opacity(0.05),
                        lineWidth: 1
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!cell.inWindow)
        } else {
            Color.clear.aspectRatio(1, contentMode: .fit)
        }
    }

    private var selectedDayHeader: some View {
        let releases = viewModel.releasesByDay[selectedDay] ?? []
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "EEEE d MMMM"
        let dayText = formatter.string(from: selectedDay)
        let countText = releases.count == 1
            ? "discovery.releases.countOne".localized
            : String(format: "discovery.releases.countMany".localized, releases.count)

        return Text("\(dayText.prefix(1).capitalized + dayText.dropFirst()) · \(countText)")
            .font(.system(size: 15.5, weight: .heavy))
            .foregroundColor(.theme.textPrimary)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)
    }

    @ViewBuilder
    private var selectedDayList: some View {
        let releases = viewModel.releasesByDay[selectedDay] ?? []
        if releases.isEmpty {
            Text("discovery.releases.none".localized)
                .font(.system(size: 13))
                .foregroundColor(Color.white.opacity(0.4))
                .padding(.horizontal, 20)
        } else {
            VStack(spacing: 10) {
                ForEach(releases) { entry in
                    NavigationLink(value: entry.showId) {
                        releaseRow(entry)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func releaseRow(_ entry: TimelineEntry) -> some View {
        HStack(spacing: 12) {
            Group {
                if let path = entry.posterPath,
                   let url = URL(string: "https://image.tmdb.org/t/p/w92\(path)") {
                    CachedAsyncImage(url: url, maxPixelSize: 150) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color.white.opacity(0.1))
                    }
                } else {
                    Rectangle().fill(Color.white.opacity(0.1))
                        .overlay { Image(systemName: "tv").font(.system(size: 13)).foregroundColor(.theme.textSecondary) }
                }
            }
            .frame(width: 36, height: 53)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(entry.label)
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundColor(.theme.accentOrange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.theme.accentOrange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Text(entry.showName ?? "tracking.unknownShow".localized)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                        .lineLimit(1)

                    if entry.isSpecial {
                        Text("tracking.special".localized)
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(.theme.textSecondary)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                if let name = entry.episodeName, !name.isEmpty {
                    Text(name)
                        .font(.system(size: 11.5))
                        .foregroundColor(.theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.theme.textSecondary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
