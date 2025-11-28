import SwiftUI
import RevenueCat

/// Paywall presented when logged-in free users watch 15 clips in a day.
struct DailyLimitPaywallView: View {
    @Binding var isPresented: Bool
    var onComeBack: (() -> Void)?

    @StateObject private var quotaManager = DailyQuotaManager.shared
    @ObservedObject private var foundingService = FoundingMemberService.shared
    @State private var countdownText = DailyQuotaManager.shared.timeUntilResetFormatted()
    @State private var showProPaywall = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var dragOffset: CGFloat = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.opacity(max(0, 0.45 * (1 - dragOffset / 400)))
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

                    BenefitList()

                    if foundingService.promoStatus.isPromoActive {
                        promoCountdownBanner
                    }

                    countdownBanner

                    upgradeButton

                    Button {
                        dismiss()
                        onComeBack?()
                    } label: {
                        Text("Come back tomorrow")
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
                        Text("Restore purchases")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.gray)
                    }

                    Text("Pro gives you unlimited clips, saved preferences, and more.")
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
                .offset(y: dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if value.translation.height > 0 {
                                dragOffset = value.translation.height
                            }
                        }
                        .onEnded { value in
                            if value.translation.height > 100 {
                                dismiss()
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
            countdownText = quotaManager.timeUntilResetFormatted()
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { alertMessage = "" }
        } message: {
            Text(alertMessage)
        }
        .fullScreenCover(isPresented: $showProPaywall) {
            ProPaywallView(isPresented: $showProPaywall) {
                dismiss()
            }
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

                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundColor(.white)
            }

            Text("You've reached today's limit")
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)

            Text("Free members can watch 15 clips per day. Upgrade to Pro for unlimited clips and premium features.")
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
                Text("Next reset in")
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

    private var promoCountdownBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Founding Member pricing")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)

                Text(foundingService.getCountdownText())
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
            showProPaywall = true
        } label: {
            VStack(spacing: 6) {
                Text("Upgrade to Pro")
                    .font(.system(size: 18, weight: .bold))
                Text("Unlock unlimited clips")
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

    private func dismiss() {
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
            let info = try await Purchases.shared.restorePurchases()
            await MainActor.run {
                if info.entitlements["StartingVibe Pro"]?.isActive == true {
                    quotaManager.upgradeToPro()
                    Task { await ClipQuotaService.shared.checkIsProUser() }
                    if let productId = info.entitlements["StartingVibe Pro"]?.productIdentifier {
                        FoundingMemberService.shared.markAsFoundingMember(
                            productId: productId,
                            userId: SupabaseService.shared.currentUser?.id
                        )
                    }
                    dismiss()
                } else {
                    presentAlert(title: "No Subscription Found", message: "We couldn’t find an active subscription for this Apple ID.")
                }
            }
        } catch {
            await MainActor.run {
                presentAlert(title: "Restore Failed", message: error.localizedDescription)
            }
        }
    }

    private struct BenefitList: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                BenefitRow(icon: "infinity", text: "Unlimited clips every day")
                BenefitRow(icon: "wand.and.stars", text: "Personalized watchlists")
                BenefitRow(icon: "sparkles", text: "Early feature access")
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

