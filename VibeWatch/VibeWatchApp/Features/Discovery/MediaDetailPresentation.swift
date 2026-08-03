import Foundation

enum PlatformSelectionCodec {
    static func decode(_ data: Data) -> Set<StreamingPlatform> {
        guard !data.isEmpty,
              let names = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }

        return Set(names.compactMap(StreamingPlatform.init(rawValue:)))
    }

    static func encode(_ platforms: Set<StreamingPlatform>) throws -> Data {
        try JSONEncoder().encode(Set(platforms.map(\.rawValue)))
    }
}

struct MediaDetailProviderPresentation {
    struct Tier {
        let titleKey: String
        let providers: [Provider]
        let link: String?
    }

    let callToActionKey: String
    let primaryProviderName: String?
    let canExpand: Bool
    let tiers: [Tier]

    static func make(from state: WatchProviderLoadState) -> MediaDetailProviderPresentation {
        guard case .available(let providers) = state else {
            return notifyMe
        }

        let tiers = WatchProviderTierGroupsBuilder.groups(in: providers).map {
            Tier(titleKey: $0.titleKey, providers: $0.providers, link: $0.justWatchLink)
        }
        guard let primaryProviderName = tiers.first?.providers.first?.providerName else {
            return notifyMe
        }

        return MediaDetailProviderPresentation(
            callToActionKey: "mediaDetail.watchOn",
            primaryProviderName: primaryProviderName,
            canExpand: true,
            tiers: tiers
        )
    }

    private static let notifyMe = MediaDetailProviderPresentation(
        callToActionKey: "mediaDetail.notifyMe",
        primaryProviderName: nil,
        canExpand: false,
        tiers: []
    )
}

enum MediaDetailFeedback {
    enum Action {
        case watchlist
        case seen
        case liked
    }

    static func messageKey(for action: Action, isActive: Bool) -> String {
        switch (action, isActive) {
        case (.watchlist, true): return "mediaDetail.toast.watchlistAdded"
        case (.watchlist, false): return "mediaDetail.toast.watchlistRemoved"
        case (.seen, true): return "mediaDetail.toast.markedSeen"
        case (.seen, false): return "mediaDetail.toast.markedUnseen"
        case (.liked, true): return "mediaDetail.toast.liked"
        case (.liked, false): return "mediaDetail.toast.likeRemoved"
        }
    }
}

enum MediaNotificationCTAState: Equatable {
    case idle
    case enabling
    case enabled

    var titleKey: String {
        switch self {
        case .idle: return "mediaDetail.notifyMe"
        case .enabling: return "mediaDetail.notifyMeEnabling"
        case .enabled: return "mediaDetail.notifyMeEnabled"
        }
    }

    var isButtonDisabled: Bool {
        self != .idle
    }
}

enum MediaNotificationEnrollmentCodec {
    static func key(userId: String?, mediaId: Int, mediaType: MediaType) -> String {
        "\(userId ?? "guest"):\(mediaType.rawValue):\(mediaId)"
    }

    static func decode(_ data: Data) -> Set<String> {
        guard !data.isEmpty,
              let keys = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return keys
    }

    static func encode(_ keys: Set<String>) throws -> Data {
        try JSONEncoder().encode(keys)
    }
}

struct WhyForMePresentation {
    struct Reason {
        let titleKey: String
        let body: String
    }

    let affinityPercent: Int
    let reasons: [Reason]

    static func make(analysis: WhyForMeAnalysis, affinityPercent: Int) -> WhyForMePresentation {
        let titleKeys = [
            "mediaDetail.why.reason.mood",
            "mediaDetail.why.reason.genres",
            "mediaDetail.why.reason.cast"
        ]
        let bodies = [analysis.mood, analysis.genres, analysis.cast]
        let reasons = zip(titleKeys, bodies).map { Reason(titleKey: $0.0, body: $0.1) }
        return WhyForMePresentation(
            affinityPercent: min(max(affinityPercent, 0), 100),
            reasons: reasons
        )
    }
}
