import Foundation

@MainActor
final class ActorDetailViewModel: ObservableObject {
    @Published var person: PersonDetails?
    @Published private(set) var allCredits: [PersonCredit] = []
    @Published var selectedFilter: MediaFilter = .all
    @Published var searchText: String = ""
    @Published var isLoading = false
    @Published var error: AppError?

    let personId: Int
    private let tmdbService: any TMDBServiceProtocol

    init(personId: Int, tmdbService: any TMDBServiceProtocol = TMDBService.shared) {
        self.personId = personId
        self.tmdbService = tmdbService
    }

    var filteredCredits: [PersonCredit] {
        let byFilter: [PersonCredit]
        switch selectedFilter {
        case .all:      byFilter = allCredits
        case .movies:   byFilter = allCredits.filter { $0.mediaType == .movie }
        case .tvSeries: byFilter = allCredits.filter { $0.mediaType == .tv }
        }
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return byFilter }
        let query = searchText.lowercased()
        return byFilter.filter { $0.title.lowercased().contains(query) }
    }

    var mostPopularCredit: PersonCredit? {
        allCredits.first
    }

    var formattedBirthday: String? {
        guard let date = person?.birthdayDate else { return nil }
        let f = DateFormatter()
        f.dateStyle = .long
        f.locale = .current
        return f.string(from: date)
    }

    var ageString: String? {
        guard let date = person?.birthdayDate else { return nil }
        let components = Calendar.current.dateComponents([.year], from: date, to: Date())
        guard let years = components.year else { return nil }
        return String(years)
    }

    var birthdayLineText: String? {
        guard let formatted = formattedBirthday else { return nil }
        if let age = ageString {
            return String(format: "actor.birthday.line".localized, formatted, age)
        }
        return formatted
    }

    func loadDetails() async {
        isLoading = true
        error = nil

        async let detailsTask = tmdbService.getPersonDetails(id: personId)
        async let creditsTask = tmdbService.getPersonCombinedCredits(id: personId)

        do {
            let (details, credits) = try await (detailsTask, creditsTask)
            person = details
            allCredits = Self.mergedCredits(cast: credits.cast, crew: credits.crew ?? [])
        } catch {
            self.error = AppError.network(error)
        }

        isLoading = false
    }

    /// One row per title: a cast credit wins over crew ones, and several crew jobs on the same
    /// title collapse into one credit with the jobs joined.
    nonisolated static func mergedCredits(cast: [PersonCredit], crew: [PersonCredit]) -> [PersonCredit] {
        var castByTitle: [String: PersonCredit] = [:]
        for credit in cast {
            let key = "\(credit.mediaType.rawValue)-\(credit.id)"
            if let existing = castByTitle[key] {
                if (credit.popularity ?? 0) > (existing.popularity ?? 0) {
                    castByTitle[key] = credit
                }
            } else {
                castByTitle[key] = credit
            }
        }

        var crewByTitle: [String: PersonCredit] = [:]
        var jobsByTitle: [String: [String]] = [:]
        for credit in crew {
            let key = "\(credit.mediaType.rawValue)-\(credit.id)"
            guard castByTitle[key] == nil else { continue }
            if let job = credit.job, !job.isEmpty {
                var jobs = jobsByTitle[key] ?? []
                if !jobs.contains(job) { jobs.append(job) }
                jobsByTitle[key] = jobs
            }
            if crewByTitle[key] == nil { crewByTitle[key] = credit }
        }

        var merged = Array(castByTitle.values)
        for (key, var credit) in crewByTitle {
            credit.job = jobsByTitle[key]?.joined(separator: ", ")
            merged.append(credit)
        }

        return merged.sorted {
            let popL = $0.popularity ?? 0
            let popR = $1.popularity ?? 0
            if popL != popR { return popL > popR }
            return ($0.releaseDate ?? "") > ($1.releaseDate ?? "")
        }
    }
}
