import SwiftUI
import RevenueCat

struct ProPaywallView: View {
    @Binding var isPresented: Bool
    var onPurchased: (() -> Void)?

    @ObservedObject private var revenueService = RevenueCatService.shared
    @ObservedObject private var foundingService = FoundingMemberService.shared
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @State private var selectedPackageID: String?
    @State private var isRefreshing = false
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Dark background matching new design
            Color(red: 18/255, green: 18/255, blue: 20/255)
                .ignoresSafeArea()
                .onTapGesture { }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Drag indicator
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 46, height: 5)
                        .padding(.top, 14)
                        .padding(.bottom, 20)
                    
                    hero

                    featuresList
                        .padding(.top, 24)
                        .padding(.bottom, 32)

                    pricingCards
                        .padding(.bottom, 24)

                    continueButton
                        .padding(.bottom, 24)

                    bottomLinks
                        .padding(.bottom, 40)
                }
                .padding(.top, 20)
            }
            .offset(y: max(0, dragOffset))
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        // Only drag when scrolled to top
                        if value.translation.height > 0 {
                            dragOffset = value.translation.height
                        }
                    }
                    .onEnded { value in
                        if value.translation.height > 150 {
                            withAnimation(.easeOut(duration: 0.25)) {
                                dismiss()
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                dragOffset = 0
                            }
                        }
                    }
            )

            // Close button
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

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 20) {
            // Orange V logo
            Image("paywall_logo")
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 1, green: 0.6, blue: 0.3), Color.orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Title
            Text("paywall.ensurePro".localized)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Features

    private var featuresList: some View {
        VStack(spacing: 14) {
            FeatureCheckRow(text: "🤖 AI-Assistant recommendations")
            FeatureCheckRow(text: "▶️ Unlimited clips")
            FeatureCheckRow(text: "📵 Offline mode")
            FeatureCheckRow(text: "📋 Up to 100 lists")
            FeatureCheckRow(text: "🔎 Advanced filters")
            FeatureCheckRow(text: "❌ No ADs")
            FeatureCheckRow(text: "🔔 Release alerts")
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Pricing

    private var pricingCards: some View {
        VStack(spacing: 12) {
            // Annual plan
            PlanOptionCard(
                planName: "Annual",
                price: annualPriceText,
                pricePerMonth: annualPerMonthText,
                discountBadge: annualDiscountBadge,
                trialBadge: annualTrialBadge,
                isSelected: selectedPackage?.storeProduct.subscriptionPeriod?.unit == .year,
                isPrimary: true
            ) {
                selectAnnualPackage()
            }

            // Monthly plan
            PlanOptionCard(
                planName: "Month",
                price: nil,
                pricePerMonth: monthlyPerMonthText,
                discountBadge: nil,
                trialBadge: monthlyTrialBadge,
                isSelected: selectedPackage?.storeProduct.subscriptionPeriod?.unit == .month,
                isPrimary: false
            ) {
                selectMonthlyPackage()
            }
        }
        .padding(.horizontal, 24)
    }

    private var annualPriceText: String? {
        guard let annual = availablePackages.first(where: { $0.storeProduct.subscriptionPeriod?.unit == .year }) else {
            return "79,99€" // fallback matching mock
        }
        return annual.storeProduct.localizedPriceString
    }

    private var annualPerMonthText: String {
        // simple: use localized price string if we have it, otherwise mock
        guard let annual = availablePackages.first(where: { $0.storeProduct.subscriptionPeriod?.unit == .year }) else {
            return "9,99€/mo"
        }
        return annual.storeProduct.localizedPriceString + "/yr"
    }

    private var monthlyPerMonthText: String {
        guard let monthly = availablePackages.first(where: { $0.storeProduct.subscriptionPeriod?.unit == .month }) else {
            return "9,99€/mo"
        }
        return monthly.storeProduct.localizedPriceString + "/mo"
    }
    
    // MARK: - Trial badges
    
    private var annualTrialBadge: String? {
        guard let annual = availablePackages.first(where: { $0.storeProduct.subscriptionPeriod?.unit == .year }),
              let trial = revenueService.getTrialInfo(for: annual) else {
            return nil
        }
        return "\(trial.localizedDuration) free"
    }
    
    private var monthlyTrialBadge: String? {
        guard let monthly = availablePackages.first(where: { $0.storeProduct.subscriptionPeriod?.unit == .month }),
              let trial = revenueService.getTrialInfo(for: monthly) else {
            return nil
        }
        return "\(trial.localizedDuration) free"
    }
    
    private var annualDiscountBadge: String? {
        // Only show discount badge if there's no trial
        // (otherwise the card gets too crowded)
        guard annualTrialBadge == nil else { return nil }
        return "33% OFF"
    }

    // MARK: - Continue button

    private var continueButton: some View {
        Button(action: handlePurchase) {
            ZStack {
                if isPurchasing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(continueButtonText)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(Color(red: 1, green: 0.55, blue: 0.2))
            .cornerRadius(30)
        }
        .disabled(selectedPackage == nil || isPurchasing)
        .padding(.horizontal, 24)
    }
    
    private var continueButtonText: String {
        guard let package = selectedPackage else { return "Select a plan" }
        
        // Check if package has a free trial
        if let trial = revenueService.getTrialInfo(for: package) {
            return "Start \(trial.localizedDuration) Free Trial"
        }
        
        return "Continue"
    }

    // MARK: - Bottom links

    private var bottomLinks: some View {
        HStack(spacing: 28) {
            Button(action: restorePurchases) {
                Text("paywall.restore".localized)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.6))
            }
            .disabled(isRestoring)

            Button(action: { /* Terms */ }) {
                Text("common.terms".localized)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.6))
            }

            Button(action: { /* Privacy */ }) {
                Text("common.privacy".localized)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.6))
            }
        }
    }

    // MARK: - RevenueCat helpers

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
        if let id = selectedPackageID,
           let match = packages.first(where: { $0.identifier == id }) {
            return match
        }
        return packages.first
    }

    private func selectAnnualPackage() {
        let packages = availablePackages
        if let annual = packages.first(where: { $0.storeProduct.subscriptionPeriod?.unit == .year }) {
            selectedPackageID = annual.identifier
        } else if let first = packages.first {
            selectedPackageID = first.identifier
        }
    }

    private func selectMonthlyPackage() {
        let packages = availablePackages
        if let monthly = packages.first(where: { $0.storeProduct.subscriptionPeriod?.unit == .month }) {
            selectedPackageID = monthly.identifier
        } else if let first = packages.first {
            selectedPackageID = first.identifier
        }
    }

    // MARK: - Purchase / restore

    private var purchaseButtonTitle: String {
        guard let package = selectedPackage else { return "Select a plan" }
        if let trial = package.storeProduct.introductoryDiscount, trial.paymentMode == .freeTrial {
            return "Start your free trial"
        }
        return "Continue with \(planLabel(for: package))"
    }

    private func planLabel(for package: Package) -> String {
        guard let period = package.storeProduct.subscriptionPeriod else {
            return package.storeProduct.localizedPriceString
        }
        switch period.unit {
        case .month: return "Monthly"
        case .year:  return "Yearly"
        case .week:  return "Weekly"
        case .day:   return "Daily"
        @unknown default:
            return package.storeProduct.localizedPriceString
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

                // Check multiple indicators of successful purchase
                let hasActiveEntitlement = result.customerInfo.entitlements[AppConstants.RevenueCat.proEntitlementID]?.isActive == true
                let hasRecentTransaction = !result.customerInfo.nonSubscriptions.isEmpty ||
                                          result.customerInfo.activeSubscriptions.contains(package.storeProduct.productIdentifier)
                let userCancelled = result.userCancelled

                print("📱 [Purchase Debug]")
                print("   - User cancelled: \(userCancelled)")
                print("   - Has active entitlement: \(hasActiveEntitlement)")
                print("   - Has recent transaction: \(hasRecentTransaction)")
                print("   - Active subscriptions: \(result.customerInfo.activeSubscriptions)")
                print("   - Product ID: \(package.storeProduct.productIdentifier)")

                await MainActor.run {
                    isPurchasing = false

                    // If purchase wasn't cancelled and we have transaction evidence, consider it successful
                    if !userCancelled && (hasActiveEntitlement || hasRecentTransaction) {
                        quotaManager.upgradeToPro()
                        FoundingMemberService.shared.markAsFoundingMember(
                            productId: package.storeProduct.productIdentifier,
                            userId: SupabaseService.shared.currentUser?.id
                        )
                        
                        // Log trial started if this was a trial purchase
                        if let trial = revenueService.getTrialInfo(for: package) {
                            let price = (package.storeProduct.price as NSDecimalNumber).doubleValue
                            AnalyticsService.shared.logTrialStarted(
                                productId: package.storeProduct.productIdentifier,
                                price: price
                            )
                            print("🎁 [Trial] Started \(trial.localizedDuration) free trial for \(package.storeProduct.productIdentifier)")
                        }
                        
                        onPurchased?()
                        dismiss()
                    } else if !userCancelled {
                        // Purchase completed but entitlement not yet active - likely sandbox delay
                        presentAlert(
                            title: "Subscription Pending",
                            message: "We couldn't confirm your Pro access yet. Please try restoring purchases or contact support."
                        )
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
                    if info.entitlements[AppConstants.RevenueCat.proEntitlementID]?.isActive == true {
                        quotaManager.upgradeToPro()
                        if let productId = info.entitlements[AppConstants.RevenueCat.proEntitlementID]?.productIdentifier {
                            FoundingMemberService.shared.markAsFoundingMember(
                                productId: productId,
                                userId: SupabaseService.shared.currentUser?.id
                            )
                        }
                        onPurchased?()
                        dismiss()
                    } else {
                        presentAlert(
                            title: "No Subscription Found",
                            message: "We couldn't find an active subscription for this Apple ID."
                        )
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
        if let rcCode = ErrorCode(rawValue: nsError.code),
           rcCode == .purchaseCancelledError {
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

// MARK: - UI subviews

/// Row with orange circular check + white text, like the mock.
private struct FeatureCheckRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(red: 1, green: 0.55, blue: 0.2))
                    .frame(width: 22, height: 22)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.black)
            }

            Text(text)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.white)

            Spacer()
        }
    }
}

/// Plan card matching the screenshot style.
private struct PlanOptionCard: View {
    let planName: String
    let price: String?
    let pricePerMonth: String
    let discountBadge: String?
    let trialBadge: String?
    let isSelected: Bool
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // Trial badge at the top (if present)
                if let trial = trialBadge {
                    HStack {
                        Spacer()
                        Text("🎁 \(trial)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                LinearGradient(
                                    colors: [Color.green.opacity(0.8), Color.green],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(12)
                        Spacer()
                    }
                    .padding(.bottom, 8)
                }
                
                ZStack(alignment: .topTrailing) {
                    HStack(spacing: 14) {
                        // Radio
                        PlanRadio(isSelected: isSelected)

                        // Inner big label box (left side)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(planName)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)

                            if let price = price {
                                Text(price)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cornerRadius(25)

                        // Right per-month price
                        Text(pricePerMonth)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(
                        Color(red: 36/255, green: 36/255, blue: 38/255)
                    )
                    .cornerRadius(26)

                    // Discount badge (only shown if no trial)
                    if let discount = discountBadge, trialBadge == nil {
                        Text(discount)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Color(red: 1, green: 0.55, blue: 0.2))
                            .cornerRadius(16)
                            .padding(.trailing, 18)
                            .padding(.top, -12)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(isPrimary ? 1.0 : 0.98)
    }
}

private struct PlanRadio: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.6), lineWidth: 2)
                .frame(width: 22, height: 22)

            if isSelected {
                Circle()
                    .fill(Color(red: 1, green: 0.55, blue: 0.2))
                    .frame(width: 22, height: 22)

                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.black)
            }
        }
    }
}

// Existing PaywallFeatureRow kept (unused in new layout but may still be handy elsewhere)
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
