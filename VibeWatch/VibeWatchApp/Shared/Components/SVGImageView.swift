import SwiftUI
import WebKit

struct SVGImageView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.loadSVG(from: url, into: uiView)
    }

    @MainActor
    final class Coordinator {
        private var currentURL: URL?
        private var task: Task<Void, Never>?

        func loadSVG(from url: URL, into webView: WKWebView) {
            guard currentURL != url else { return }
            currentURL = url
            task?.cancel()

            task = Task { [weak webView] in
                let html: String
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let svg = String(data: data, encoding: .utf8) {
                        html = """
                        <html>
                        <head>
                        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
                        <style>
                            body { margin: 0; padding: 0; background-color: transparent; display: flex; justify-content: center; align-items: center; height: 100vh; }
                            svg { width: 100%; height: 100%; }
                        </style>
                        </head>
                        <body>
                        \(svg)
                        </body>
                        </html>
                        """
                    } else {
                        html = Self.imgHTML(for: url)
                    }
                } catch {
                    html = Self.imgHTML(for: url)
                }

                webView?.loadHTMLString(html, baseURL: nil)
            }
        }

        private static func imgHTML(for url: URL) -> String {
            """
            <html>
            <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                body { margin: 0; padding: 0; background-color: transparent; display: flex; justify-content: center; align-items: center; height: 100vh; }
                img { width: 100%; height: 100%; object-fit: contain; }
            </style>
            </head>
            <body>
                <img src="\(url.absoluteString)" />
            </body>
            </html>
            """
        }
    }
}
