import SwiftUI
import RevenueCat

struct PaywallBottomSheet: View {
    @StateObject private var quotaManager = DailyQuotaManager.shared
    @ObservedObject private var foundingService = FoundingMemberService.shared
    @Environment(\.dismiss) private var dismiss
    @Binding var isPresented: Bool
    var onComeBack: (() -> Void)? // parent can provide navigation action

    @State private var currentTime = Date()
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var isPurchasing = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Blurred background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .blur(radius: 20)

            VStack(spacing: 0) {
                Spacer()

                // Bottom sheet content
                VStack(spacing: 24) {
                    // Drag indicator
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.4))
                        .frame(width: 40, height: 5)
                        .padding(.top, 12)

                    // Header with emoji
                    VStack(spacing: 12) {
                        Text("🎬")
                            .font(.system(size: 60))

                        Text("You've watched your 15 free clips today")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Text("Unlock unlimited clips to keep discovering amazing content")
                            .font(.system(size: 16))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    // Feature list
                    VStack(alignment: .leading, spacing: 16) {
                        FeatureRow(icon: "infinity", text: "Unlimited clips every day")
                        FeatureRow(icon: "sparkles", text: "AI-powered personalization")
                        FeatureRow(icon: "bolt.fill", text: "Ad-free experience")
                        FeatureRow(icon: "wand.and.stars", text: "Early access to new features")
                    }
                    .padding(.horizontal, 24)

                    if foundingService.promoStatus.isPromoActive {
                        promoCountdownBanner
                            .padding(.horizontal, 24)
                    }

                    // Upgrade button -> show alert "available soon"
                    Button {
                        handleUpgrade()
                    } label: {
                        ZStack {
                            HStack(spacing: 8) {
                                Text(isPurchasing ? "Processing..." : "Upgrade to Pro")
                                    .font(.system(size: 18, weight: .bold))
                                
                                if !isPurchasing {
                                    Text("€9.99/month")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(.white.opacity(0.8))
                                }
                            }
                            .opacity(isPurchasing ? 0 : 1)
                            
                            if isPurchasing {
                                ProgressView()
                                    .tint(.white)
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            LinearGradient(
                                colors: [Color.orange, Color.orange.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(16)
                        .shadow(color: Color.orange.opacity(0.3), radius: 10, x: 0, y: 5)
                    }
                    .disabled(isPurchasing)
                    .padding(.horizontal, 24)

                    // Secondary action - Come back tomorrow
                    VStack(spacing: 8) {
                        Button {
                            // Dismiss sheet and tell parent to navigate to DiscoveryView
                            dismiss()
                            onComeBack?()
                        } label: {
                            HStack(spacing: 6) {
                                Text("Come back tomorrow")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.gray)

                                Image(systemName: "arrow.forward")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.gray)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.gray.opacity(0.15))
                            .cornerRadius(14)
                        }

                        // Countdown timer
                        HStack(spacing: 4) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.gray.opacity(0.7))

                            Text("Resets in \(quotaManager.timeUntilResetFormatted())")
                                .font(.system(size: 13))
                                .foregroundColor(.gray.opacity(0.7))
                        }
                        .onReceive(timer) { _ in
                            currentTime = Date()
                        }
                    }
                    .padding(.horizontal, 24)

                    // Sign in reminder for anonymous users
                    if SupabaseService.shared.currentUser == nil {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.blue.opacity(0.8))

                            Text("Sign in to unlock 15 new clips tomorrow")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.blue.opacity(0.8))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(12)
                        .padding(.horizontal, 24)
                    }

                    // Terms
                    Text("Subscription auto-renews. Cancel anytime.")
                        .font(.system(size: 11))
                        .foregroundColor(.gray.opacity(0.6))
                        .padding(.top, 4)
                        .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(UIColor.systemBackground))
                        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: -10)
                )
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isPresented)
        // Alert
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) {
                alertMessage = ""
            }
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - Actions
        
        private func handleUpgrade() {
            guard !isPurchasing else { return }
            isPurchasing = true
            Task {
                do {
                    let package = try await loadPreferredPackage()
                    let result = try await Purchases.shared.purchase(package: package)
                    let isPro = result.customerInfo.entitlements["StartingVibe Pro"]?.isActive == true
                    await MainActor.run {
                        isPurchasing = false
                        if isPro {
                            quotaManager.upgradeToPro()
                            Task { await ClipQuotaService.shared.checkIsProUser() }
                            FoundingMemberService.shared.markAsFoundingMember(
                                productId: package.storeProduct.productIdentifier,
                                userId: SupabaseService.shared.currentUser?.id
                            )
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
        
        private func loadPreferredPackage() async throws -> Package {
            if let package = selectPackage(from: RevenueCatService.shared.offerings) {
                return package
            }
            await RevenueCatService.shared.refreshOfferings(debug: false)
            if let package = selectPackage(from: RevenueCatService.shared.offerings) {
                return package
            }
            throw PaywallError.packageUnavailable
        }
        
        private func selectPackage(from offerings: Offerings?) -> Package? {
            guard let offerings else { return nil }
            let desiredOrder = [FoundingMemberService.shared.getCurrentOffering(), "founding_member", "default"]
            var visited = Set<String>()
            for identifier in desiredOrder where visited.insert(identifier).inserted {
                if let offering = offerings.offering(identifier: identifier),
                   let package = offering.availablePackages.first {
                    return package
                }
            }
            if let offering = offerings.current ?? offerings.all.values.first,
               let package = offering.availablePackages.first {
                return package
            }
            return nil
        }
        
        private func handlePurchaseError(_ error: Error) {
            if let paywallError = error as? PaywallError {
                presentAlert(title: "Unavailable", message: paywallError.localizedDescription)
                return
            }
            let nsError = error as NSError
            if let rcCode = ErrorCode(rawValue: nsError.code),
               rcCode == .purchaseCancelledError {
                return
            }
            let message = nsError.localizedDescription
            presentAlert(title: "Purchase Failed", message: message)
        }
        
        private func presentAlert(title: String, message: String) {
            alertTitle = title
            alertMessage = message
            showAlert = true
        }

        private var promoCountdownBanner: some View {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Founding Member pricing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text(foundingService.getCountdownText())
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }

                Spacer()
            }
            .padding()
            .background(Color.orange.opacity(0.12))
            .cornerRadius(16)
        }
    }

    private enum PaywallError: LocalizedError {
        case packageUnavailable
        
        var errorDescription: String? {
            switch self {
            case .packageUnavailable:
                return "No subscription packages are currently available. Please try again later."
            }
        }
    }

    // MARK: - Supporting View

    struct FeatureRow: View {
        let icon: String
        let text: String
        
        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.orange)
                    .frame(width: 24)
                
                Text(text)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                
                Spacer()
            }
        }
    }

    // MARK: - Preview

    #Preview {
        PaywallBottomSheet(isPresented: .constant(true))
            .preferredColorScheme(.dark)
    }
