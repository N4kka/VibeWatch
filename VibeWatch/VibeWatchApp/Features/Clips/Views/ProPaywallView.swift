import SwiftUI
import RevenueCat
import StoreKit

struct ProPaywallView: View {
    @Binding var isPresented: Bool
    let source: String
    var isOnboarding: Bool = false
    var onPurchased: (() -> Void)?

    @ObservedObject private var revenueService = RevenueCatService.shared
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @State private var selectedPackageID: String?
    @State private var isRefreshing = false
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var dragOffset: CGFloat = 0
    @State private var didCompletePurchaseOrRestore = false

    // Transaction listener for code redemption
    @State private var transactionListenerTask: Task<Void, Never>?
    
    private var accentColor: Color {
        Color(red: 1, green: 0.55, blue: 0.2)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [
                    Color(red: 30/255, green: 24/255, blue: 24/255),
                    Color(red: 14/255, green: 14/255, blue: 16/255)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            // Dark background matching new design
            Color(red: 18/255, green: 18/255, blue: 20/255)
                .ignoresSafeArea()
                .onTapGesture { }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if !isOnboarding {
                        // Drag indicator
                        Capsule()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 46, height: 5)
                            .padding(.top, 14)
                            .padding(.bottom, 20)
                    } else {
                        // Spacer for onboarding to push content down slightly
                        Color.clear.frame(height: 60)
                    }
                    
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
                                dismiss(action: "swipe_down", logDismiss: true)
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                dragOffset = 0
                            }
                        }
                    }
            )

            // Close button
            if isOnboarding {
                Button {
                    dismiss(action: "skip", logDismiss: true)
                } label: {
                    Text("paywall.cta.skip".localized)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.3))
                        .clipShape(Capsule())
                        .padding()
                }
            } else {
                Button {
                    dismiss(action: "close", logDismiss: true)
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
        }
        .task {
            await refreshOfferingsIfNeeded()
            AnalyticsService.shared.logPaywallViewed(source: source, type: "pro")
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { alertMessage = "" }
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 12) {
            // Orange V logo
            Image("paywall_logo")
                .foregroundStyle(
                    LinearGradient(
                        colors: [accentColor, Color.orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Title
            Text("paywall.ensurePro".localized)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)

            Text("paywall.proDescription".localized)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
    }
    
    private var featureKeys: [String] {
        [
            "paywall.feature.aiAssistant",
            "paywall.feature.unlimitedClips",
            "paywall.feature.offlineMode",
            "paywall.feature.lists",
            "paywall.feature.advancedFilters",
            "paywall.feature.noAds",
            "paywall.feature.releaseAlerts"
        ]
    }

    // MARK: - Features

    private var featuresList: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("paywall.unlockUnlimited".localized)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .padding(.bottom, 4)

            VStack(spacing: 12) {
                ForEach(featureKeys, id: \.self) { key in
                    FeatureCheckRow(text: key.localized)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .cornerRadius(22)
        .padding(.horizontal, 24)
    }

    // MARK: - Pricing

    private var pricingCards: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("paywall.cta.selectPlan".localized)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 4)

            // Annual plan
            PlanOptionCard(
                planName: "paywall.plan.annual".localized,
                price: annualPriceText,
                pricePerMonth: annualPerMonthText,
                discountBadge: annualDiscountBadge,
                trialBadge: annualTrialBadge,
                isSelected: selectedPackageID != nil && selectedPackageID == annualPackage?.identifier,
                isPrimary: true,
                accentColor: accentColor
            ) {
                selectAnnualPackage()
            }

            // Monthly plan
            PlanOptionCard(
                planName: "paywall.plan.monthly".localized,
                price: monthlyPriceText,
                pricePerMonth: monthlyPerMonthText,
                discountBadge: nil,
                trialBadge: monthlyTrialBadge,
                isSelected: selectedPackageID != nil && selectedPackageID == monthlyPackage?.identifier,
                isPrimary: false,
                accentColor: accentColor
            ) {
                selectMonthlyPackage()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .cornerRadius(22)
        .padding(.horizontal, 24)
    }

    private var annualPriceText: String? {
        guard let annual = annualPackage else {
            return nil
        }
        return annual.storeProduct.localizedPriceString
    }

    private var annualPerMonthText: String {
        guard let annual = annualPackage else {
            return String(format: "paywall.price.perMonth".localized, "—")
        }
        return formattedPerMonthPrice(for: annual.storeProduct, months: 12)
    }

    private var monthlyPerMonthText: String {
        guard let monthly = monthlyPackage else {
            return String(format: "paywall.price.perMonth".localized, "—")
        }
        return formattedPerMonthPrice(for: monthly.storeProduct, months: 1)
    }

    private var monthlyPriceText: String? {
        guard let monthly = monthlyPackage else { return nil }
        return monthly.storeProduct.localizedPriceString
    }

    // MARK: - Trial badges
    
    private var annualTrialBadge: String? {
        guard let annual = annualPackage,
              let trial = revenueService.getTrialInfo(for: annual) else {
            return nil
        }
        return String(format: "paywall.trial.badge".localized, trial.localizedDuration)
    }
    
    private var monthlyTrialBadge: String? {
        guard let monthly = monthlyPackage,
              let trial = revenueService.getTrialInfo(for: monthly) else {
            return nil
        }
        return String(format: "paywall.trial.badge".localized, trial.localizedDuration)
    }
    
    private var annualDiscountBadge: String? {
        // Only show discount badge if there's no trial
        // (otherwise the card gets too crowded)
        guard annualTrialBadge == nil else { return nil }
        return "paywall.discount.annual".localized
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
            .background(
                LinearGradient(
                    colors: [accentColor, Color.orange],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(30)
            .shadow(color: accentColor.opacity(0.35), radius: 12, x: 0, y: 8)
        }
        .disabled(selectedPackage == nil || isPurchasing)
        .padding(.horizontal, 24)
        .id(selectedPackageID)
    }
    
    private var continueButtonText: String {
        guard let package = selectedPackage else { return "paywall.cta.selectPlan".localized }
        
        // Check if package has a free trial
        if let trial = revenueService.getTrialInfo(for: package) {
            return startTrialText(duration: trial.localizedDuration)
        }
        
        return "paywall.cta.continue".localized
    }
    
    private func startTrialText(duration: String) -> String {
        let template = "paywall.cta.startTrial".localized
        guard template.contains("%@") else { return template }
        return String(format: template, duration)
    }

    // MARK: - Bottom links

    private var bottomLinks: some View {
        VStack(spacing: 16) {
            // Promo code link - prominent placement for creators
            Button(action: presentOfferCodeRedemption) {
                HStack(spacing: 6) {
                    Image(systemName: "ticket.fill")
                        .font(.system(size: 12))
                    Text("paywall.haveCode".localized)
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(accentColor)
            }

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
    }

    /// Present Apple's native offer code redemption sheet
    private func presentOfferCodeRedemption() {
        // Start listening for transactions before showing the sheet
        startTransactionListener()

        SKPaymentQueue.default().presentCodeRedemptionSheet()
        print("🎟️ [Paywall] Presenting offer code redemption sheet")
    }

    /// Listen for StoreKit transactions after code redemption
    private func startTransactionListener() {
        // Cancel any existing listener
        transactionListenerTask?.cancel()

        transactionListenerTask = Task {
            // Listen for new transactions from StoreKit 2
            for await result in Transaction.updates {
                switch result {
                case .verified(let transaction):
                    print("🎟️ [Paywall] Transaction detected: \(transaction.productID)")

                    // Sync with RevenueCat to update entitlements
                    await syncPurchasesWithRevenueCat()

                    // Always finish the transaction
                    await transaction.finish()
                case .unverified(_, let error):
                    print("⚠️ [Paywall] Transaction verification failed: \(error)")
                }
            }
        }
    }

    /// Sync purchases with RevenueCat after code redemption
    private func syncPurchasesWithRevenueCat() async {
        do {
            // Sync purchases forces RevenueCat to check with Apple for new transactions
            let customerInfo = try await Purchases.shared.syncPurchases()
            let isPro = customerInfo.entitlements[AppConstants.RevenueCat.proEntitlementID]?.isActive == true

            if isPro {
                print("✅ [Paywall] Code redeemed successfully! PRO status activated")
                await MainActor.run {
                    quotaManager.upgradeToPro()
                    onPurchased?()
                    didCompletePurchaseOrRestore = true
                    dismiss(logDismiss: false)
                }
                // Also refresh the ClipQuotaService to update its cached status
                await ClipQuotaService.shared.checkIsProUser()
            }
        } catch {
            print("⚠️ [Paywall] Failed to sync purchases: \(error)")
            // Still try to check PRO status directly
            await ClipQuotaService.shared.checkIsProUser()
        }
    }

    // MARK: - RevenueCat helpers

    private let monthlyPriorityIds = [
        "vibewatch_pro_monthly_standard"
    ]
    
    private let annualPriorityIds = [
        "vibewatch_pro_yearly_standard"
    ]
    
    private var availablePackages: [Package] {
        guard let offerings = revenueService.offerings else { return [] }
        
        // Merge packages from priority offerings, keeping unique identifiers so we don't drop monthly/annual options.
        var orderedPackages: [Package] = []
        var seen: Set<String> = []
        
        func append(from offering: Offering?) {
            guard let offering else { return }
            for package in offering.availablePackages where !seen.contains(package.identifier) {
                seen.insert(package.identifier)
                orderedPackages.append(package)
            }
        }

        // Priority order
        if let currentID = revenueService.currentOfferingID {
            append(from: offerings.offering(identifier: currentID))
        }
        append(from: offerings.offering(identifier: "default"))
        append(from: offerings.current)
        
        // Fallback: any remaining offerings
        for offering in offerings.all.values {
            append(from: offering)
        }
        
        return orderedPackages
    }

    private var annualPackage: Package? {
        prioritizedPackage(
            priorityIds: annualPriorityIds,
            period: .year
        )
    }
    
    private var monthlyPackage: Package? {
        prioritizedPackage(
            priorityIds: monthlyPriorityIds,
            period: .month
        )
    }
    
    private func prioritizedPackage(priorityIds: [String], period: RevenueCat.SubscriptionPeriod.Unit) -> Package? {
        let periodPackages = availablePackages
            .filter { $0.storeProduct.subscriptionPeriod?.unit == period }
            .sorted { lhs, rhs in
                NSDecimalNumber(decimal: lhs.storeProduct.price).doubleValue <
                NSDecimalNumber(decimal: rhs.storeProduct.price).doubleValue
            }
        
        // 1) Prefer explicit product IDs in priority order
        for id in priorityIds {
            if let match = periodPackages.first(where: { $0.storeProduct.productIdentifier == id }) {
                return match
            }
        }
        
        // 2) Fallback to cheapest for the period
        return periodPackages.first
    }

    private var selectedPackage: Package? {
        let packages = availablePackages
        guard !packages.isEmpty else { return nil }
        if let id = selectedPackageID,
           let match = packages.first(where: { $0.identifier == id }) {
            return match
        }
        return annualPackage ?? packages.first
    }

    private func selectAnnualPackage() {
        if let annual = annualPackage {
            selectedPackageID = annual.identifier
        } else if let first = availablePackages.first {
            selectedPackageID = first.identifier
        }
    }

    private func selectMonthlyPackage() {
        if let monthly = monthlyPackage {
            selectedPackageID = monthly.identifier
        } else if let first = availablePackages.first {
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
    
    private func formattedPerMonthPrice(for product: StoreProduct, months: Int) -> String {
        let divisor = NSDecimalNumber(value: months)
        let monthlyPriceDecimal = (product.price as NSDecimalNumber).dividing(by: divisor)
        let formattedPrice = formatPrice(monthlyPriceDecimal.decimalValue, for: product)
        return String(format: "paywall.price.perMonth".localized, formattedPrice)
    }
    
    private func formatPrice(_ price: Decimal, for product: StoreProduct) -> String {
        let number = NSDecimalNumber(decimal: price)
        if let formatter = product.priceFormatter {
            return formatter.string(from: number) ?? product.localizedPriceString
        }
        
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        return formatter.string(from: number) ?? product.localizedPriceString
    }

    @MainActor
    private func refreshOfferings() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await RevenueCatService.shared.refreshOfferings(debug: true)
            await MainActor.run {
                isRefreshing = false
                setDefaultPackageIfNeeded()
            }
        }
    }

    @MainActor
    private func refreshOfferingsIfNeeded() async {
        if revenueService.offerings == nil {
            await RevenueCatService.shared.refreshOfferings(debug: true)
            setDefaultPackageIfNeeded()
        }
    }

    @MainActor
    private func setDefaultPackageIfNeeded() {
        guard selectedPackageID == nil else { return }
        if let annual = annualPackage {
            selectedPackageID = annual.identifier
        } else {
            selectedPackageID = availablePackages.first?.identifier
        }
    }

    private func handlePurchase() {
        guard let package = selectedPackage, !isPurchasing else { return }
        isPurchasing = true
        AnalyticsService.shared.logPaywallCTAClicked(source: source, cta: "continue")
        AnalyticsService.shared.logEvent("purchase_started", parameters: [
            "product_id": package.storeProduct.productIdentifier
        ])
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
                        didCompletePurchaseOrRestore = true
                        quotaManager.upgradeToPro()

                        let price = NSDecimalNumber(decimal: package.storeProduct.price).doubleValue
                        AnalyticsService.shared.logSubscriptionPurchased(
                            productId: package.storeProduct.productIdentifier,
                            price: price
                        )
                        
                        // Log trial started if this was a trial purchase
                        if let trial = revenueService.getTrialInfo(for: package) {
                            AnalyticsService.shared.logTrialStarted(
                                productId: package.storeProduct.productIdentifier,
                                price: price
                            )
                            print("🎁 [Trial] Started \(trial.localizedDuration) free trial for \(package.storeProduct.productIdentifier)")
                        }
                        
                        onPurchased?()
                        dismiss(logDismiss: false)
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
                    AnalyticsService.shared.logEvent("purchase_failed", parameters: [
                        "error": (error as NSError).localizedDescription
                    ])
                    handlePurchaseError(error)
                }
            }
        }
    }

    private func restorePurchases() {
        guard !isRestoring else { return }
        isRestoring = true
        AnalyticsService.shared.logEvent("restore_started", parameters: [:])
        Task {
            do {
                let info = try await Purchases.shared.restorePurchases()
                await MainActor.run {
                    isRestoring = false
                    if info.entitlements[AppConstants.RevenueCat.proEntitlementID]?.isActive == true {
                        didCompletePurchaseOrRestore = true
                        quotaManager.upgradeToPro()
                        onPurchased?()
                        AnalyticsService.shared.logEvent("restore_succeeded", parameters: [:])
                        dismiss(logDismiss: false)
                    } else {
                        AnalyticsService.shared.logEvent("restore_no_active_subscription", parameters: [:])
                        presentAlert(
                            title: "No Subscription Found",
                            message: "We couldn't find an active subscription for this Apple ID."
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    isRestoring = false
                    AnalyticsService.shared.logEvent("restore_failed", parameters: [
                        "error": (error as NSError).localizedDescription
                    ])
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

    private func dismiss(action: String = "close", logDismiss: Bool = true) {
        if logDismiss, !didCompletePurchaseOrRestore {
            AnalyticsService.shared.logPaywallDismissed(source: source, action: action)
        }
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
    let accentColor: Color
    let action: () -> Void
    
    private var badgeText: String? { trialBadge ?? discountBadge }
    private var isTrialBadge: Bool { trialBadge != nil }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    PlanRadio(isSelected: isSelected, accentColor: accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(planName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))

                        if let price = price {
                            Text(price)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }

                    Spacer()

                    if let badge = badgeText {
                        badgeView(text: badge, isTrial: isTrialBadge)
                    }
                }

                HStack {
                    if isPrimary {
                        Text("paywall.bestValue".localized)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(accentColor)
                            .cornerRadius(12)
                    }
                    
                    Spacer()
                    
                    Text(pricePerMonth)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(12)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
            )
            .cornerRadius(22)
            .shadow(
                color: isSelected ? accentColor.opacity(0.25) : Color.black.opacity(0.2),
                radius: isSelected ? 12 : 8,
                x: 0,
                y: isSelected ? 10 : 6
            )
        }
        .buttonStyle(.plain)
        .opacity(isPrimary ? 1.0 : 0.98)
    }

    private var cardBackground: Color {
        Color.white.opacity(isSelected ? 0.09 : 0.04)
    }

    private var borderColor: Color {
        isSelected ? accentColor : Color.white.opacity(0.12)
    }

    private func badgeView(text: String, isTrial: Bool) -> some View {
        Text(isTrial ? "🎁 \(text)" : text)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(isTrial ? .black : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                LinearGradient(
                    colors: isTrial
                    ? [Color.green.opacity(0.85), Color.green]
                    : [accentColor.opacity(0.8), accentColor],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(12)
    }
}

private struct PlanRadio: View {
    let isSelected: Bool
    let accentColor: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.6), lineWidth: 2)
                .frame(width: 22, height: 22)

            if isSelected {
                Circle()
                    .fill(accentColor)
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
