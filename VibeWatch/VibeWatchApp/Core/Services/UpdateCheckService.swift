import Foundation

@MainActor
final class UpdateCheckService {
    static let shared = UpdateCheckService()

    private init() {}

    private struct UpdateConfig: Decodable {
        let minimumVersion: String
        let latestVersion: String?
        let title: String?
        let message: String?
        let releaseNotes: [String]?
        let appStoreURL: String?

        enum CodingKeys: String, CodingKey {
            case minimumVersion = "minimum_version"
            case latestVersion = "latest_version"
            case title
            case message
            case releaseNotes = "release_notes"
            case appStoreURL = "app_store_url"
        }
    }

    func checkForRequiredUpdate() async -> UpdateRequirement? {
        guard let configURL = URL(string: Config.updateConfigURL), !Config.updateConfigURL.isEmpty else {
            return nil
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: configURL)
            let config = try JSONDecoder().decode(UpdateConfig.self, from: data)
            guard isUpdateRequired(minimumVersion: config.minimumVersion) else {
                return nil
            }

            let appStoreURL = config.appStoreURL ?? Config.appStoreURL
            guard !appStoreURL.isEmpty else { return nil }

            return UpdateRequirement(
                minimumVersion: config.minimumVersion,
                latestVersion: config.latestVersion,
                title: config.title ?? "Update required",
                message: config.message,
                releaseNotes: config.releaseNotes ?? [],
                appStoreURL: appStoreURL
            )
        } catch {
            Logger.warning("[UpdateCheckService] Failed to fetch update config: \(error)")
            return nil
        }
    }

    private func isUpdateRequired(minimumVersion: String) -> Bool {
        guard let current = AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String),
              let minimum = AppVersion(minimumVersion) else {
            return false
        }
        return current < minimum
    }
}

private struct AppVersion: Comparable {
    private let components: [Int]

    init?(_ value: String?) {
        guard let value, !value.isEmpty else { return nil }
        components = value.split(separator: ".").map { Int($0) ?? 0 }
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let maxCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<maxCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
