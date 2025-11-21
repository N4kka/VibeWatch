import Foundation

enum ListError: Error {
    case maxListsReached(limit: Int)
    case maxItemsReached(limit: Int)
    case listNotFound
    case itemAlreadyInList
    
    var localizedDescription: String {
        switch self {
        case .maxListsReached(let limit):
            return "lists.error.maxListsReached".localized.replacingOccurrences(of: "{limit}", with: "\(limit)")
        case .maxItemsReached(let limit):
            return "lists.error.maxItemsReached".localized.replacingOccurrences(of: "{limit}", with: "\(limit)")
        case .listNotFound:
            return "lists.error.listNotFound".localized
        case .itemAlreadyInList:
            return "lists.error.itemAlreadyInList".localized
        }
    }
}

@MainActor
class ListManager: ObservableObject {
    static let shared = ListManager()
    
    // Limits for free tier
    static let maxCustomLists = 2
    static let maxItemsPerList = 25
    
    @Published var lists: [MediaList] = []
    @Published var watchlist: MediaList
    @Published var seenList: MediaList
    @Published var likedList: MediaList
    @Published var dislikedList: MediaList

    private init() {
        // Initialize default lists
        self.watchlist = MediaList(name: "lists.watchlist".localized, type: .watchlist)
        self.seenList = MediaList(name: "lists.seen".localized, type: .seen)
        self.likedList = MediaList(name: "lists.liked".localized, type: .liked)
        self.dislikedList = MediaList(name: "lists.disliked".localized, type: .disliked)

        loadLists()
    }
    
    func loadLists() {
        // Load from UserDefaults for now (replace with Supabase later)
        if let data = UserDefaults.standard.data(forKey: "media_lists"),
           let decoded = try? JSONDecoder().decode([MediaList].self, from: data) {
            self.lists = decoded
            
            // Update default lists
            if let watchlist = decoded.first(where: { $0.type == .watchlist }) {
                self.watchlist = watchlist
            }
            if let seen = decoded.first(where: { $0.type == .seen }) {
                self.seenList = seen
            }
            if let liked = decoded.first(where: { $0.type == .liked }) {
                self.likedList = liked
            }
            if let disliked = decoded.first(where: { $0.type == .disliked }) {
                self.dislikedList = disliked
            }
        } else {
            // Initialize with default lists
            self.lists = [watchlist, seenList, likedList, dislikedList]
            saveLists()
        }
    }
    
    func saveLists() {
        if let encoded = try? JSONEncoder().encode(lists) {
            UserDefaults.standard.set(encoded, forKey: "media_lists")
        }
    }
    
    func createList(name: String, description: String? = nil) -> Result<Void, ListError> {
        // Check if custom list limit reached
        let customListCount = lists.filter { $0.type == .custom }.count
        guard customListCount < Self.maxCustomLists else {
            return .failure(.maxListsReached(limit: Self.maxCustomLists))
        }
        
        let newList = MediaList(name: name, description: description, type: .custom)
        lists.append(newList)
        saveLists()
        return .success(())
    }
    
    func canCreateList() -> Bool {
        let customListCount = lists.filter { $0.type == .custom }.count
        return customListCount < Self.maxCustomLists
    }
    
    func customListsCount() -> Int {
        lists.filter { $0.type == .custom }.count
    }
    
    func deleteList(_ list: MediaList) {
        lists.removeAll { $0.id == list.id }
        saveLists()
    }
    
    func addToList(listId: String, movie: Movie, mediaType: MediaType) -> Result<Void, ListError> {
        guard let index = lists.firstIndex(where: { $0.id == listId }) else {
            return .failure(.listNotFound)
        }
        
        // Check if already in list
        if lists[index].items.contains(where: { $0.mediaId == movie.id && $0.mediaType == mediaType }) {
            return .failure(.itemAlreadyInList)
        }
        
        // Check item limit for custom lists
        if lists[index].type == .custom && lists[index].items.count >= Self.maxItemsPerList {
            return .failure(.maxItemsReached(limit: Self.maxItemsPerList))
        }
        
        // Extract origin country codes from production countries
        let originCountry = movie.productionCountries?.map { $0.iso }
        
        // Get genre IDs from either genreIds or genres array
        let genreIds = movie.genreIds ?? movie.genres?.map { $0.id }
        
        let item = MediaListItem(
            mediaId: movie.id,
            mediaType: mediaType,
            title: movie.title,
            posterPath: movie.posterPath,
            runtime: movie.runtime,
            voteAverage: movie.voteAverage,
            voteCount: movie.voteCount,
            originCountry: originCountry,
            releaseDate: movie.releaseDate,
            genres: genreIds,
            overview: movie.overview
        )
        
        objectWillChange.send()
        lists[index].items.append(item)
        
        // Update special lists
        if lists[index].type == .watchlist {
            watchlist = lists[index]
        } else if lists[index].type == .seen {
            seenList = lists[index]
        } else if lists[index].type == .liked {
            likedList = lists[index]
        } else if lists[index].type == .disliked {
            dislikedList = lists[index]
        }
        
        saveLists()
        return .success(())
    }
    
    func canAddToList(listId: String) -> Bool {
        guard let list = lists.first(where: { $0.id == listId }) else { return false }
        if list.type == .custom {
            return list.items.count < Self.maxItemsPerList
        }
        return true // No limit for default lists
    }
    
    func removeFromList(listId: String, itemId: String) {
        guard let index = lists.firstIndex(where: { $0.id == listId }) else { return }
        objectWillChange.send()
        lists[index].items.removeAll { $0.id == itemId }
        
        // Update special lists
        if lists[index].type == .watchlist {
            watchlist = lists[index]
        } else if lists[index].type == .seen {
            seenList = lists[index]
        } else if lists[index].type == .liked {
            likedList = lists[index]
        } else if lists[index].type == .disliked {
            dislikedList = lists[index]
        }
        
        saveLists()
    }
    
    func isInList(listId: String, mediaId: Int, mediaType: MediaType) -> Bool {
        guard let list = lists.first(where: { $0.id == listId }) else { return false }
        return list.items.contains(where: { $0.mediaId == mediaId && $0.mediaType == mediaType })
    }
}
