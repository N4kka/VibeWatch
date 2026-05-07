import SwiftUI

/// Drop-in replacement for AsyncImage that uses URLCache for offline support
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    
    @State private var image: UIImage?
    @State private var isLoading = false
    
    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }
    
    var body: some View {
        Group {
            if let image = image {
                content(Image(uiImage: image))
            } else {
                placeholder()
                    .task {
                        await loadImage()
                    }
            }
        }
    }
    
    @MainActor
    private func loadImage() async {
        guard let url = url, !isLoading else { return }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let loadedImage = try await ImageCacheService.shared.loadImage(from: url.absoluteString)
            self.image = loadedImage
        } catch {
            Logger.error("[CachedAsyncImage] Failed to load: \(error.localizedDescription)")
        }
    }
}

// Convenience initializer matching AsyncImage API
extension CachedAsyncImage where Content == Image, Placeholder == Color {
    init(url: URL?) {
        self.url = url
        self.content = { $0.resizable() }
        self.placeholder = { Color.gray.opacity(0.2) }
    }
}
