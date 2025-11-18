import Foundation

@MainActor
class ListManager: ObservableObject {
    static let shared = ListManager()
    
    @Published var lists: [MediaList] = []
    @Published var watchlist: MediaList
    @Published var seenList: MediaList
    @Published var likedList: MediaList
    @Published var dislikedList: MediaList
    
    private init() {
        // Initialize default lists
        self.watchlist = MediaList(name: "Watchlist", type: .watchlist)
        self.seenList = MediaList(name: "Seen", type: .seen)
        self.likedList = MediaList(name: "Liked", type: .liked)
        self.dislikedList = MediaList(name: "Disliked", type: .disliked)
        
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
    
    func createList(name: String) {
        let newList = MediaList(name: name, type: .custom)
        lists.append(newList)
        saveLists()
    }
    
    func deleteList(_ list: MediaList) {
        lists.removeAll { $0.id == list.id }
        saveLists()
    }
    
    func addToList(listId: String, movie: Movie, mediaType: MediaType) {
        guard let index = lists.firstIndex(where: { $0.id == listId }) else { return }
        
        let item = MediaListItem(
            mediaId: movie.id,
            mediaType: mediaType,
            title: movie.title,
            posterPath: movie.posterPath
        )
        
        // Check if already in list
        if !lists[index].items.contains(where: { $0.mediaId == movie.id && $0.mediaType == mediaType }) {
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
        }
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
