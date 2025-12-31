import SwiftUI
import GoogleMobileAds

struct BannerAdView: UIViewRepresentable {
    let adUnitID: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> BannerViewContainer {
        let container = BannerViewContainer()
        container.bannerView.adUnitID = adUnitID
        container.bannerView.delegate = context.coordinator
        return container
    }

    func updateUIView(_ container: BannerViewContainer, context: Context) {
        // Set root view controller
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            container.bannerView.rootViewController = rootViewController
        }

        // Load ad if not already loaded for this container
        if !container.hasLoadedAd {
            let width = container.frame.width > 0 ? container.frame.width : UIScreen.main.bounds.width
            let adSize = currentOrientationAnchoredAdaptiveBanner(width: width)
            container.bannerView.adSize = adSize
            container.bannerView.load(Request())
            container.hasLoadedAd = true
        }
    }

    class Coordinator: NSObject, BannerViewDelegate {
        func bannerViewDidReceiveAd(_ bannerView: BannerView) {
            print("Banner ad loaded successfully")
        }

        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
            print("Banner ad failed to load: \(error.localizedDescription)")
        }
    }
}

class BannerViewContainer: UIView {
    let bannerView = BannerView()
    var hasLoadedAd = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(bannerView)
        bannerView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bannerView.centerXAnchor.constraint(equalTo: centerXAnchor),
            bannerView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

#Preview {
    BannerAdView(adUnitID: AppConstants.AdMob.bannerAdUnitID)
        .frame(height: 50)
}
