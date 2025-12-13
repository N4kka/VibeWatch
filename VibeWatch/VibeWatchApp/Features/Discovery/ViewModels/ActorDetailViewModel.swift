import Foundation

@MainActor
final class ActorDetailViewModel: ObservableObject {
    @Published var person: PersonDetails?
    @Published var movieCredits: [PersonCredit] = []
    @Published var tvCredits: [PersonCredit] = []
    @Published var isLoading = false
    @Published var error: AppError?
    
    private let personId: Int
    private let tmdbService = TMDBService.shared
    
    init(personId: Int) {
        self.personId = personId
    }
    
    func loadDetails() async {
        isLoading = true
        error = nil
        
        async let detailsTask = tmdbService.getPersonDetails(id: personId)
        async let creditsTask = tmdbService.getPersonCombinedCredits(id: personId)
        
        do {
            let (details, credits) = try await (detailsTask, creditsTask)
            person = details
            movieCredits = credits.cast
                .filter { $0.mediaType == .movie }
                .sorted(by: sortByDateDescending)
            tvCredits = credits.cast
                .filter { $0.mediaType == .tv }
                .sorted(by: sortByDateDescending)
        } catch {
            self.error = AppError.network(error)
        }
        
        isLoading = false
    }
    
    private func sortByDateDescending(_ lhs: PersonCredit, _ rhs: PersonCredit) -> Bool {
        guard let left = lhs.releaseDate, let right = rhs.releaseDate else {
            return lhs.releaseDate != nil
        }
        return left > right
    }
}
