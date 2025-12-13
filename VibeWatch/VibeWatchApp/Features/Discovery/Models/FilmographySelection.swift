import Foundation

struct FilmographySelection: Identifiable {
    let mediaType: MediaType
    let mediaId: Int
    
    var id: String {
        "\(mediaType.rawValue)-\(mediaId)"
    }
}
