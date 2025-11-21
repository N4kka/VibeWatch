import SwiftUI

struct AsyncImageView: View {
    let url: URL?
    let contentMode: ContentMode
    
    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
    }
    
    var body: some View {
        Group {
            if let url = url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        placeholderView
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                    case .failure:
                        placeholderView
                    @unknown default:
                        placeholderView
                    }
                }
            } else {
                placeholderView
            }
        }
    }
    
    private var placeholderView: some View {
        Rectangle()
            .fill(Color.theme.backgroundDark.opacity(0.3))
            .overlay {
                Image(systemName: "film")
                    .font(.largeTitle)
                    .foregroundColor(.theme.textSecondary)
            }
    }
}
