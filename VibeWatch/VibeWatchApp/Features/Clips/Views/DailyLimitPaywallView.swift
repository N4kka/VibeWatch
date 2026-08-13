import SwiftUI
import RevenueCat

enum PaywallType {
    case clipsQuota
    case aiQuota
    
    var title: String {
        switch self {
        case .clipsQuota: return "paywall.daily.limitReached".localizedMainSafe()
        case .aiQuota: return "ai.paywall.title".localizedMainSafe()
        }
    }
    
    var description: String {
        switch self {
        case .clipsQuota: return "paywall.daily.limitDescription".localizedMainSafe()
        case .aiQuota: return "ai.paywall.description".localizedMainSafe()
        }
    }
    
    var upgradeButtonText: String {
        switch self {
        case .clipsQuota: return "paywall.upgrade".localizedMainSafe()
        case .aiQuota: return "paywall.upgrade".localizedMainSafe()
        }
    }
    
    var unlockMessage: String {
        switch self {
        case .clipsQuota: return "paywall.unlockUnlimited".localizedMainSafe()
        case .aiQuota: return "ai.paywall.unlockAI".localizedMainSafe()
        }
    }
    
    var goBack: String {
        switch self {
            case .clipsQuota: return "paywall.daily.title".localizedMainSafe()
        case .aiQuota: return "ai.paywall.goBack".localizedMainSafe()
        }
    }
    
    var heroImage: String {
        switch self {
        case .clipsQuota: return "clock.badge.exclamationmark"
        case .aiQuota: return "sparkles.tv"
        }
    }
}

/// Paywall presented when logged-in free users watch 25 clips in a day.
struct DailyLimitPaywallView: View {
    @Binding var isPresented: Bool
    var onComeBack: (() -> Void)?
    let paywallType: PaywallType // New property
    let source: String
    
    @StateObject private var quotaManager = DailyQuotaManager.shared
    @State private var countdownText = DailyQuotaManager.shared.timeUntilResetFormatted()
    @State private var showProPaywall = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var dragOffset: CGFloat = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(
        isPresented: Binding<Bool>,
        onComeBack: (() -> Void)? = nil,
        paywallType: PaywallType = .clipsQuota,
        source: String = "unknown"
    ) {
        self._isPresented = isPresented
        self.onComeBack = onComeBack
        self.paywallType = paywallType
        self.source = source
    }

    var body: some View {
        ZStack {
            Color.black.opacity(max(0, 0.45 * (1.0 - Double(dragOffset) / 400.0)))
                .ignoresSafeArea()
                .onTapGesture { }

            VStack {
                Spacer()

                VStack(spacing: 24) {
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 46, height: 5)
                        .padding(.top, 14)

                    heroSection

                    BenefitList(paywallType: paywallType) // Pass paywallType

                    if paywallType == .clipsQuota { // Only show countdown for clips quota
                        countdownBanner
                    }

                    upgradeButton

                    Button {
                        dismiss(action: "come_back", logDismiss: true)
                        onComeBack?()
                    } label: {
                        Text(paywallType.goBack)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.gray.opacity(0.15))
                            .cornerRadius(14)
                    }

                    Button {
                        Task { await restorePurchases() }
                    } label: {
                        Text("paywall.restore".localized)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.gray)
                    }

                    Text("paywall.proDescription".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .padding(.bottom, 20)
                }
                .padding(.horizontal, 24)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color(UIColor.systemBackground))
                        .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: -8)
                )
                .offset(y: max(0, dragOffset))
                .highPriorityGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            if value.translation.height > 0 {
                                dragOffset = value.translation.height
                            }
                        }
                        .onEnded { value in
                            if value.translation.height > 150 {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    dismiss(action: "swipe_down", logDismiss: true)
                                }
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .onReceive(timer) { _ in
            if paywallType == .clipsQuota { // Only update countdown for clips
                countdownText = quotaManager.timeUntilResetFormatted()
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { alertMessage = "" }
        } message: {
            Text(alertMessage)
        }
        .fullScreenCover(isPresented: $showProPaywall) {
            ProPaywallView(isPresented: $showProPaywall, source: "\(source)_upgrade") {
                dismiss(action: "purchase_success", logDismiss: false)
            }
        }
        .task {
            AnalyticsService.shared.logPaywallViewed(
                source: source,
                type: paywallType == .clipsQuota ? "daily_limit" : "ai_limit"
            )
        }
    }

    private var heroSection: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(LinearGradient(
                        colors: [Color.orange, Color.pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 110, height: 110)
                    .shadow(color: Color.orange.opacity(0.3), radius: 22, x: 0, y: 10)

                Image(systemName: paywallType.heroImage)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundColor(.white)
            }

            Text(paywallType.title)
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)

            Text(paywallType.description)
                .font(.system(size: 15))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
    }

    private var countdownBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "timer")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("paywall.daily.nextReset".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)

                Text(countdownText)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }

            Spacer()
        }
        .padding(14)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(16)
    }

    private var upgradeButton: some View {
        Button {
            AnalyticsService.shared.logPaywallCTAClicked(source: source, cta: "upgrade")
            showProPaywall = true
        } label: {
            VStack(spacing: 6) {
                Text(paywallType.upgradeButtonText)
                    .font(.system(size: 18, weight: .bold))
                Text(paywallType.unlockMessage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                LinearGradient(
                    colors: [Color.orange, Color.orange.opacity(0.85)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(18)
            .shadow(color: Color.orange.opacity(0.35), radius: 12, x: 0, y: 6)
        }
    }

    private func dismiss(action: String = "close", logDismiss: Bool = true) {
        if logDismiss {
            AnalyticsService.shared.logPaywallDismissed(source: source, action: action)
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            isPresented = false
        }
    }

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }

    private func restorePurchases() async {
        do {
            AnalyticsService.shared.track(.restoreStarted(properties: [:]))
            let info = try await Purchases.shared.restorePurchases()
            await MainActor.run {
                if info.entitlements["StartingVibe Pro"]?.isActive == true {
                    quotaManager.upgradeToPro()
                    Task { await ClipQuotaService.shared.checkIsProUser() }
                    AnalyticsService.shared.track(.restoreSucceeded(properties: [:]))
                    dismiss(action: "restore_success", logDismiss: false)
                } else {
                    AnalyticsService.shared.track(.restoreNoActiveSubscription(properties: [:]))
                    presentAlert(title: "No Subscription Found", message: "We couldn’t find an active subscription for this Apple ID.")
                }
            }
        } catch {
            await MainActor.run {
                AnalyticsService.shared.track(.restoreFailed(properties: [
                    "error": (error as NSError).localizedDescription
                ]))
                presentAlert(title: "Restore Failed", message: error.localizedDescription)
            }
        }
    }

    private struct BenefitList: View {
        let paywallType: PaywallType // New property

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                // Benefits are dynamic based on paywallType
                switch paywallType {
                case .clipsQuota:
                    BenefitRow(icon: "infinity", text: "Unlimited clips every day")
                    BenefitRow(icon: "wand.and.stars", text: "Personalized watchlists")
                    BenefitRow(icon: "sparkles", text: "Early feature access")
                case .aiQuota:
                    BenefitRow(icon: "brain.head.profile", text: "ai.paywall.benefit.unlimited".localized)
                    BenefitRow(icon: "sparkles.tv", text: "ai.paywall.benefit.smarter".localized)
                    BenefitRow(icon: "wand.and.stars", text: "ai.paywall.benefit.personalized".localized)
                }
            }
        }
    }

    private struct BenefitRow: View {
        let icon: String
        let text: String

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.orange)
                    .frame(width: 28)

                Text(text)
                    .font(.system(size: 15))
                    .foregroundColor(.white)

                Spacer()
            }
            .padding()
            .background(Color.white.opacity(0.08))
            .cornerRadius(14)
        }
    }
}
