import Foundation

/// Pure action-button state derived from media-list membership.
enum MovieActionButtonStateBuilder {

    struct State: Equatable {
        let isInAnyList: Bool
        let isInSeen: Bool
        let isInLiked: Bool
        let isInDisliked: Bool
        let likesCount: Int
        let dislikesCount: Int
    }

    static func state(
        mediaId: Int,
        mediaType: MediaType,
        lists: [MediaList],
        seenList: MediaList,
        likedList: MediaList,
        dislikedList: MediaList
    ) -> State {
        State(
            isInAnyList: lists.contains { contains($0, mediaId: mediaId, mediaType: mediaType) },
            isInSeen: contains(seenList, mediaId: mediaId, mediaType: mediaType),
            isInLiked: contains(likedList, mediaId: mediaId, mediaType: mediaType),
            isInDisliked: contains(dislikedList, mediaId: mediaId, mediaType: mediaType),
            likesCount: count(in: likedList, mediaId: mediaId, mediaType: mediaType),
            dislikesCount: count(in: dislikedList, mediaId: mediaId, mediaType: mediaType)
        )
    }

    private static func contains(_ list: MediaList, mediaId: Int, mediaType: MediaType) -> Bool {
        list.items.contains { $0.mediaId == mediaId && $0.mediaType == mediaType }
    }

    private static func count(in list: MediaList, mediaId: Int, mediaType: MediaType) -> Int {
        list.items.filter { $0.mediaId == mediaId && $0.mediaType == mediaType }.count
    }
}
