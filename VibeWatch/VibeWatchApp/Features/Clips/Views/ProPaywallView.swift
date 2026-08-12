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
        Color.theme.accentOrange
    }

    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    header
                        .padding(.top, 8)

                    heroCard

                    featuresCard

                    pricingRow
                        .padding(.top, 4)

                    continueButton
                        .padding(.top, 4)

                    bottomLinks
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                }
                .padding(.horizontal, 20)
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

    // MARK: - Header

    // Come nel prototipo: back circolare a sinistra e titolo centrato. In onboarding la porta
    // è "Salta per ora" a destra, perché lì non c'è nessuna schermata a cui "tornare".
    private var header: some View {
        ZStack {
            Text("VibeWatch Pro")
                .font(.system(size: 19, weight: .heavy))
                .foregroundColor(.theme.textPrimary)

            HStack {
                if isOnboarding {
                    Spacer()
                    Button {
                        dismiss(action: "skip", logDismiss: true)
                    } label: {
                        Text("paywall.cta.skip".localized)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Capsule())
                    }
                } else {
                    BackCircleButton { dismiss(action: "close", logDismiss: true) }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("paywall.upgrade".localized)
                .font(.system(size: 26, weight: .heavy))
                .foregroundColor(.theme.textPrimary)

            Text("paywall.proDescription".localized)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            LinearGradient(
                colors: [accentColor.opacity(0.28), accentColor.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(accentColor.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
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

    private var featuresCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(featureKeys.enumerated()), id: \.element) { index, key in
                if index > 0 {
                    Divider().background(Color.white.opacity(0.06))
                }
                FeatureCheckRow(text: cleanedFeatureText(key.localized))
            }
        }
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    /// Le stringhe delle feature hanno un'emoji davanti (le usa ancora il paywall della quota
    /// giornaliera); qui il segno di spunta arancione fa già da icona.
    private func cleanedFeatureText(_ text: String) -> String {
        String(text.drop(while: { !($0.isLetter || $0.isNumber) }))
    }

    // MARK: - Pricing

    private var pricingRow: some View {
        HStack(spacing: 12) {
            PlanOptionCard(
                caption: "paywall.bestValue".localized,
                price: annualPriceText,
                priceSuffix: priceSuffix(from: "paywall.price.perYear"),
                subtitle: annualPerMonthText,
                isSelected: selectedPackageID != nil && selectedPackageID == annualPackage?.identifier,
                accentColor: accentColor
            ) {
                selectAnnualPackage()
            }

            PlanOptionCard(
                caption: "paywall.plan.monthly".localized.uppercased(),
                price: monthlyPriceText,
                priceSuffix: priceSuffix(from: "paywall.price.perMonth"),
                subtitle: "paywall.cancelAnytime".localized,
                isSelected: selectedPackageID != nil && selectedPackageID == monthlyPackage?.identifier,
                accentColor: accentColor
            ) {
                selectMonthlyPackage()
            }
        }
    }

    /// Da "%@/anno" ricava "/anno": il prezzo grande e il suffisso piccolo sono due Text
    /// distinti nel mock, ma la stringa localizzata resta una sola.
    private func priceSuffix(from key: String) -> String {
        key.localized
            .replacingOccurrences(of: "%@", with: "")
            .trimmingCharacters(in: .whitespaces)
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

    // MARK: - Continue button

    private var continueButton: some View {
        Button(action: handlePurchase) {
            ZStack {
                if isPurchasing {
                    ProgressView()
                        .tint(Color.theme.background)
                } else {
                    Text(continueButtonText)
                        .font(.system(size: 17, weight: .bold))
                        // Testo scuro su arancio: la stessa inversione del FAB e dello switcher.
                        .foregroundColor(.theme.background)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                LinearGradient(
                    colors: [accentColor, Color(hex: "e56a20")],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: accentColor.opacity(0.3), radius: 12, x: 0, y: 8)
        }
        .disabled(selectedPackage == nil || isPurchasing)
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

                Link(destination: termsURL) {
                    Text("common.terms".localized)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.6))
                }

                Link(destination: privacyURL) {
                    Text("common.privacy".localized)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.6))
                }
            }
        }
    }

    private var termsURL: URL { URL(string: "https://vibewatch.vercel.app/terms")! }
    private var privacyURL: URL { URL(string: "https://vibewatch.vercel.app/privacy")! }

    /// Present Apple's native offer code redemption sheet
    private func presentOfferCodeRedemption() {
        // Start listening for transactions before showing the sheet
        startTransactionListener()

        SKPaymentQueue.default().presentCodeRedemptionSheet()
        Logger.info("[Paywall] Presenting offer code redemption sheet")
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
                    Logger.info("[Paywall] Transaction detected: \(transaction.productID)")

                    // Sync with RevenueCat to update entitlements
                    await syncPurchasesWithRevenueCat()

                    // Always finish the transaction
                    await transaction.finish()
                case .unverified(_, let error):
                    Logger.warning("[Paywall] Transaction verification failed: \(error)")
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
                Logger.info("[Paywall] Code redeemed successfully! PRO status activated")
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
            Logger.warning("[Paywall] Failed to sync purchases: \(error)")
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

                Logger.debug("[Purchase] userCancelled=\(userCancelled), hasActiveEntitlement=\(hasActiveEntitlement), hasRecentTransaction=\(hasRecentTransaction), activeSubscriptions=\(result.customerInfo.activeSubscriptions), productID=\(package.storeProduct.productIdentifier)")

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
                            Logger.info("[Trial] Started \(trial.localizedDuration) free trial for \(package.storeProduct.productIdentifier)")
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

/// Riga della lista feature: spunta in cerchio tinto arancio + testo, separate da divider
/// nella card, come nel prototipo.
private struct FeatureCheckRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.theme.accentOrange.opacity(0.15))
                    .frame(width: 26, height: 26)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.theme.accentOrange)
            }

            Text(text)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundColor(.theme.textPrimary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

/// Card piano affiancate come nel prototipo: caption in alto, prezzo grande con suffisso
/// piccolo, sottotitolo. La selezione è il bordo arancio + fondo tinto.
private struct PlanOptionCard: View {
    let caption: String
    let price: String?
    let priceSuffix: String
    let subtitle: String
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(caption)
                    .font(.system(size: 11, weight: .heavy))
                    .kerning(0.8)
                    .foregroundColor(isSelected ? accentColor : Color(hex: "8a8b90"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(price ?? "—")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(.theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(priceSuffix)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(hex: "8a8b90"))
                }

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "8a8b90"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(isSelected ? accentColor.opacity(0.08) : Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        isSelected ? accentColor : Color.white.opacity(0.1),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
