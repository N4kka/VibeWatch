import Foundation

@MainActor
final class ActorDetailViewModel: ObservableObject {
    @Published var person: PersonDetails?
    @Published private(set) var allCredits: [PersonCredit] = []
    @Published var selectedFilter: MediaFilter = .all
    @Published var isLoading = false
    @Published var error: AppError?

    private let personId: Int
    private let tmdbService: any TMDBServiceProtocol

    init(personId: Int, tmdbService: any TMDBServiceProtocol = TMDBService.shared) {
        self.personId = personId
        self.tmdbService = tmdbService
    }

    var filteredCredits: [PersonCredit] {
        switch selectedFilter {
        case .all:      return allCredits
        case .movies:   return allCredits.filter { $0.mediaType == .movie }
        case .tvSeries: return allCredits.filter { $0.mediaType == .tv }
        }
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

            // Deduplicate by composite key (mediaType + id), keeping highest popularity
            var seen: [String: PersonCredit] = [:]
            for credit in credits.cast {
                let key = "\(credit.mediaType.rawValue)-\(credit.id)"
                if let existing = seen[key] {
                    if (credit.popularity ?? 0) > (existing.popularity ?? 0) {
                        seen[key] = credit
                    }
                } else {
                    seen[key] = credit
                }
            }

            allCredits = Array(seen.values).sorted {
                let popL = $0.popularity ?? 0
                let popR = $1.popularity ?? 0
                if popL != popR { return popL > popR }
                return ($0.releaseDate ?? "") > ($1.releaseDate ?? "")
            }
        } catch {
            self.error = AppError.network(error)
        }

        isLoading = false
    }
}
