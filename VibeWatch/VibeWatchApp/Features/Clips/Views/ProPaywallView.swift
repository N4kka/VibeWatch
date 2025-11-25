import SwiftUI
import RevenueCat

struct ProPaywallView: View {
    @Binding var isPresented: Bool
    var onPurchased: (() -> Void)?

    @ObservedObject private var revenueService = RevenueCatService.shared
    @ObservedObject private var foundingService = FoundingMemberService.shared
    @State private var selectedPackageID: String?
    @State private var isRefreshing = false
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [Color(red: 16/255, green: 16/255, blue: 20/255), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 28) {
                    hero

                    if foundingService.promoStatus.isPromoActive {
                        promoBanner
                    }

                    pricingSection

                    featureSection

                    actionButtons

                    Text("Subscription auto-renews. Cancel anytime in Settings.")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 24)
                .padding(.top, 60)
                .padding(.bottom, 40)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
                    .padding()
            }
        }
        .task {
            await refreshOfferingsIfNeeded()
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { alertMessage = "" }
        } message: {
            Text(alertMessage)
        }
    }

    private var hero: some View {
        VStack(spacing: 16) {
            ZStack {
                LinearGradient(colors: [Color.orange, Color.pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: 120, height: 120)
                    .cornerRadius(36)
                    .shadow(color: Color.orange.opacity(0.4), radius: 25, x: 0, y: 16)

                Image(systemName: "sparkles")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(spacing: 8) {
                Text("VibeWatch Pro")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)

                Text("Unlimited clips, personalized lists, and upcoming pro-only perks.")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var pricingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Choose your plan")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                if isRefreshing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Button(action: refreshOfferings) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
            }

            if availablePackages.isEmpty {
                VStack(spacing: 12) {
                    Text("We couldn't load pricing options.")
                        .foregroundColor(.gray)
                    Button("Try Again") {
                        refreshOfferings()
                    }
                    .font(.system(size: 15, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(18)
            } else {
                VStack(spacing: 16) {
                    ForEach(availablePackages, id: \.identifier) { package in
                        PricingCard(
                            planName: planLabel(for: package),
                            priceText: planPriceLine(for: package),
                            descriptionText: planDescription(for: package),
                            trialText: trialText(for: package),
                            discountText: discountText(for: package),
                            isBestValue: isAnnualPackage(package),
                            isSelected: (selectedPackageID ?? availablePackages.first?.identifier) == package.identifier
                        ) {
                            selectedPackageID = package.identifier
                        }
                        .onAppear {
                            if selectedPackageID == nil {
                                selectedPackageID = package.identifier
                            }
                        }
                    }
                }
            }
        }
    }

    private var featureSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What's included")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)

            VStack(spacing: 14) {
                PaywallFeatureRow(icon: "infinity", title: "Unlimited clips every day", subtitle: "No daily limits, keep discovering.")
                PaywallFeatureRow(icon: "sparkles", title: "Personalized lists", subtitle: "Advanced organization and filters.")
                PaywallFeatureRow(icon: "bolt.fill", title: "Early feature access", subtitle: "Founding members get perks first.")
                PaywallFeatureRow(icon: "wand.and.stars", title: "Coming soon", subtitle: "Alerts, advanced filters, and more.")
            }
            .padding(18)
            .background(Color.white.opacity(0.05))
            .cornerRadius(20)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 16) {
            Button(action: handlePurchase) {
                ZStack {
                    if isPurchasing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        VStack(spacing: 4) {
                            Text(purchaseButtonTitle)
                                .font(.system(size: 18, weight: .bold))
                            if let subtitle = purchaseButtonSubtitle {
                                Text(subtitle)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 62)
                .background(
                    LinearGradient(colors: [Color.orange, Color(red: 1, green: 0.55, blue: 0.2)], startPoint: .leading, endPoint: .trailing)
                )
                .cornerRadius(18)
                .shadow(color: Color.orange.opacity(0.35), radius: 14, x: 0, y: 8)
            }
            .disabled(selectedPackage == nil || isPurchasing)

            Button(action: restorePurchases) {
                HStack(spacing: 8) {
                    if isRestoring {
                        ProgressView()
                            .tint(.white)
                    }
                    Text("Restore purchases")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
        }
    }

    private var promoBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text("Founding member pricing")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text(foundingService.getCountdownText())
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
            }

            Spacer()
        }
        .padding(16)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(18)
    }

    private var availablePackages: [Package] {
        guard let offerings = revenueService.offerings else { return [] }
        var identifiers: [String] = []
        identifiers.append(foundingService.getCurrentOffering())
        if let current = revenueService.currentOfferingID {
            identifiers.append(current)
        }
        identifiers.append(contentsOf: ["founding_member", "default"])

        for identifier in identifiers {
            if let offering = offerings.offering(identifier: identifier), !offering.availablePackages.isEmpty {
                return offering.availablePackages
            }
        }

        if let current = offerings.current, !current.availablePackages.isEmpty {
            return current.availablePackages
        }

        return offerings.all.values.flatMap { $0.availablePackages }
    }

    private var selectedPackage: Package? {
        let packages = availablePackages
        guard !packages.isEmpty else { return nil }
        if let id = selectedPackageID, let match = packages.first(where: { $0.identifier == id }) {
            return match
        }
        return packages.first
    }

    private var purchaseButtonTitle: String {
        guard let package = selectedPackage else { return "Select a plan" }
        if let trial = package.storeProduct.introductoryDiscount, trial.paymentMode == .freeTrial {
            return "Start your free trial"
        }
        return "Continue with \(planLabel(for: package))"
    }

    private var purchaseButtonSubtitle: String? {
        guard let package = selectedPackage else { return nil }
        if let trial = package.storeProduct.introductoryDiscount, trial.paymentMode == .freeTrial {
            return formattedTrialText(for: trial)
        }
        return planPriceLine(for: package)
    }

    private func planLabel(for package: Package) -> String {
        guard let period = package.storeProduct.subscriptionPeriod else { return package.storeProduct.localizedPriceString }
        switch period.unit {
        case .month: return "Monthly"
        case .year: return "Yearly"
        case .week: return "Weekly"
        case .day: return "Daily"
        @unknown default: return package.storeProduct.localizedPriceString
        }
    }

    private func planPriceLine(for package: Package) -> String {
        return package.storeProduct.localizedPriceString
    }

    private func planDescription(for package: Package) -> String? {
        guard let period = package.storeProduct.subscriptionPeriod else { return nil }
        switch period.unit {
        case .month: return "Billed monthly"
        case .year: return "Billed annually"
        case .week: return "Billed weekly"
        case .day: return "Billed daily"
        @unknown default: return nil
        }
    }

    private func trialText(for package: Package) -> String? {
        guard let trial = package.storeProduct.introductoryDiscount, trial.paymentMode == .freeTrial else {
            return nil
        }
        return formattedTrialText(for: trial)
    }

    private func discountText(for package: Package) -> String? {
        guard isFoundingPackage(package) else { return nil }
        return "Founding member price • 50% OFF"
    }

    private func isAnnualPackage(_ package: Package) -> Bool {
        package.storeProduct.subscriptionPeriod?.unit == .year
    }

    private func isFoundingPackage(_ package: Package) -> Bool {
        guard foundingService.promoStatus.isPromoActive else { return false }
        let identifier = package.identifier.lowercased()
        let productId = package.storeProduct.productIdentifier.lowercased()
        return identifier.contains("founding") || productId.contains("founding")
    }

    private func formattedTrialText(for discount: StoreProductDiscount) -> String {
        let period = discount.subscriptionPeriod
        let value = period.value
        switch period.unit {
        case .day:
            return value == 1 ? "1 day free" : "\(value) days free"
        case .week:
            return value == 1 ? "1 week free" : "\(value) weeks free"
        case .month:
            return value == 1 ? "1 month free" : "\(value) months free"
        case .year:
            return value == 1 ? "1 year free" : "\(value) years free"
        @unknown default:
            return "Free trial"
        }
    }

    @MainActor
    private func refreshOfferings() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await RevenueCatService.shared.refreshOfferings(debug: false)
            await MainActor.run {
                isRefreshing = false
                if selectedPackageID == nil {
                    selectedPackageID = availablePackages.first?.identifier
                }
            }
        }
    }

    @MainActor
    private func refreshOfferingsIfNeeded() async {
        if revenueService.offerings == nil {
            await RevenueCatService.shared.refreshOfferings(debug: false)
            if selectedPackageID == nil {
                selectedPackageID = availablePackages.first?.identifier
            }
        }
    }

    private func handlePurchase() {
        guard let package = selectedPackage, !isPurchasing else { return }
        isPurchasing = true
        Task {
            do {
                let result = try await Purchases.shared.purchase(package: package)
                let isPro = result.customerInfo.entitlements["StartingVibe Pro"]?.isActive == true
                await MainActor.run {
                    isPurchasing = false
                    if isPro {
                        DailyQuotaManager.shared.upgradeToPro()
                        Task { await ClipQuotaService.shared.checkIsProUser() }
                        FoundingMemberService.shared.markAsFoundingMember(
                            productId: package.storeProduct.productIdentifier,
                            userId: SupabaseService.shared.currentUser?.id
                        )
                        onPurchased?()
                        dismiss()
                    } else {
                        presentAlert(title: "Subscription Pending", message: "We couldn't confirm your Pro access yet. Please try restoring purchases or contact support.")
                    }
                }
            } catch {
                await MainActor.run {
                    isPurchasing = false
                    handlePurchaseError(error)
                }
            }
        }
    }

    private func restorePurchases() {
        guard !isRestoring else { return }
        isRestoring = true
        Task {
            do {
                let info = try await Purchases.shared.restorePurchases()
                await MainActor.run {
                    isRestoring = false
                    if info.entitlements["StartingVibe Pro"]?.isActive == true {
                        DailyQuotaManager.shared.upgradeToPro()
                        Task { await ClipQuotaService.shared.checkIsProUser() }
                        if let productId = info.entitlements["StartingVibe Pro"]?.productIdentifier {
                            FoundingMemberService.shared.markAsFoundingMember(
                                productId: productId,
                                userId: SupabaseService.shared.currentUser?.id
                            )
                        }
                        onPurchased?()
                        dismiss()
                    } else {
                        presentAlert(title: "No Subscription Found", message: "We couldn't find an active subscription for this Apple ID.")
                    }
                }
            } catch {
                await MainActor.run {
                    isRestoring = false
                    presentAlert(title: "Restore Failed", message: error.localizedDescription)
                }
            }
        }
    }

    private func handlePurchaseError(_ error: Error) {
        let nsError = error as NSError
        if let rcCode = ErrorCode(rawValue: nsError.code), rcCode == .purchaseCancelledError {
            return
        }
        presentAlert(title: "Purchase Failed", message: nsError.localizedDescription)
    }

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isPresented = false
        }
    }
}

private struct PaywallFeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.orange)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)

                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.8))
            }

            Spacer()
        }
    }
}
