import GoogleMobileAds
import UIKit

@MainActor
class InterstitialAdManager: NSObject, ObservableObject {
    static let shared = InterstitialAdManager()

    @Published private(set) var isAdReady = false
    private var interstitialAd: InterstitialAd?
    private var clipsSinceLastAd = 0

    private override init() {
        super.init()
        Task {
            await loadAd()
        }
    }

    /// Call this when a clip is watched to track ad frequency
    func recordClipWatched(isProUser: Bool) {
        guard !isProUser else { return }

        clipsSinceLastAd += 1
        print("Clips since last ad: \(clipsSinceLastAd)")

        if clipsSinceLastAd >= AppConstants.AdMob.clipsPerInterstitial {
            showAdIfReady()
        }
    }

    /// Show the interstitial ad if one is loaded
    func showAdIfReady() {
        guard let ad = interstitialAd else {
            print("Interstitial ad not ready, loading...")
            Task { await loadAd() }
            return
        }

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            print("No root view controller found")
            return
        }

        print("Presenting interstitial ad...")
        ad.present(from: rootViewController)
    }

    /// Preload an interstitial ad using async/await
    func loadAd() async {
        do {
            interstitialAd = try await InterstitialAd.load(
                with: AppConstants.AdMob.interstitialAdUnitID,
                request: Request()
            )
            interstitialAd?.fullScreenContentDelegate = self
            isAdReady = true
            print("Interstitial ad loaded successfully")
        } catch {
            print("Interstitial ad failed to load: \(error.localizedDescription)")
            isAdReady = false
        }
    }

    /// Reset clip counter (e.g., when user becomes Pro)
    func resetCounter() {
        clipsSinceLastAd = 0
    }
}

extension InterstitialAdManager: FullScreenContentDelegate {
    nonisolated func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        Task { @MainActor in
            print("Interstitial ad dismissed")
            interstitialAd = nil
            clipsSinceLastAd = 0
            isAdReady = false
            await loadAd()
        }
    }

    nonisolated func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        Task { @MainActor in
            print("Interstitial ad failed to present: \(error.localizedDescription)")
            interstitialAd = nil
            isAdReady = false
            await loadAd()
        }
    }

    nonisolated func adWillPresentFullScreenContent(_ ad: FullScreenPresentingAd) {
        print("Interstitial ad will present")
        NotificationCenter.default.post(name: .pauseAllClips, object: nil)
    }

    nonisolated func adDidRecordImpression(_ ad: FullScreenPresentingAd) {
        print("Interstitial ad recorded impression")
    }

    nonisolated func adDidRecordClick(_ ad: FullScreenPresentingAd) {
        print("Interstitial ad recorded click")
    }
}
