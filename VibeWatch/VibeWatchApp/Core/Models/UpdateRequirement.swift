import Foundation

struct UpdateRequirement: Identifiable, Equatable {
    let id = UUID()
    let minimumVersion: String
    let latestVersion: String?
    let title: String
    let message: String?
    let releaseNotes: [String]
    let appStoreURL: String
}
