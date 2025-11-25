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
                CachedAsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } placeholder: {
                    placeholderView
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
