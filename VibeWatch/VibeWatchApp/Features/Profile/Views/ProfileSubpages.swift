import SwiftUI

// Redesign 2.0 — le due sottopagine del profilo che nel prototipo hanno una pagina propria
// e nell'app stavano annegate dentro Impostazioni: la cache immagini e privacy/termini.
// Impostazioni resta (paese, debug, il resto); queste sono le porte dirette dal profilo.

// MARK: - Cache immagini

struct ImageCacheSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: ImageCacheService.CacheSizePreference =
        ImageCacheService.shared.getCurrentCacheSizePreference()
    @State private var diskUsageMB: Int = 0
    @State private var showClearConfirm = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("settings.cacheManagement.cacheSizeDescription".localized)
                        .font(.system(size: 12.5))
                        .foregroundColor(.theme.textSecondary)
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        ForEach(Array(ImageCacheService.CacheSizePreference.allCases.enumerated()),
                                id: \.element) { index, option in
                            if index > 0 {
                                Divider().background(Color.white.opacity(0.06))
                            }
                            Button {
                                selected = option
                                ImageCacheService.shared.setCacheSizePreference(option)
                            } label: {
                                HStack {
                                    Text(option.rawValue)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(selected == option ? .theme.textPrimary : .theme.textSecondary)
                                    Spacer()
                                    if selected == option {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(.theme.accentOrange)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 13)
                            }
                        }
                    }
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    Button {
                        showClearConfirm = true
                    } label: {
                        HStack {
                            Text("settings.cacheManagement.clearCache".localized)
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundColor(Color(hex: "ff5b5b"))
                            Spacer()
                            // L'occupazione vera su disco, non la preferenza: il numero che
                            // spiega cosa libererà il tap.
                            Text(String(format: "settings.cacheManagement.inUse".localized, diskUsageMB))
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "8a8b90"))
                        }
                        .padding(14)
                        .background(Color(hex: "ff5b5b").opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color(hex: "ff5b5b").opacity(0.25), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.top, 4)

                    Text("settings.cacheManagement.prefetchDescription".localized)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "6c6d73"))
                        .padding(.horizontal, 4)
                }
                .padding(20)
            }
            .background(Color.theme.background.ignoresSafeArea())
            .navigationTitle("profile.imageCache".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityLabel(Text("common.close".localized))
                }
            }
            .confirmationDialog("settings.cacheManagement.clearCacheWarning".localized,
                                isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("settings.cacheManagement.clearCache".localized, role: .destructive) {
                    ImageCacheService.shared.clearCache()
                    diskUsageMB = 0
                }
                Button("common.cancel".localized, role: .cancel) {}
            }
            .onAppear {
                diskUsageMB = ImageCacheService.shared.getCacheStats().diskUsage / 1_048_576
            }
        }
    }
}

// MARK: - Privacy e termini

struct PrivacyTermsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("analytics.isEnabled") private var analyticsEnabled: Bool = true

    private let privacyURL = URL(string: "https://vibewatch.vercel.app/privacy")!
    private let termsURL = URL(string: "https://vibewatch.vercel.app/terms")!

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.analytics.share".localized)
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundColor(.theme.textPrimary)
                            Text("settings.analytics.share.description".localized)
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "8a8b90"))
                        }
                        Spacer()
                        Toggle("", isOn: $analyticsEnabled)
                            .labelsHidden()
                            .tint(.theme.accentOrange)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .onChange(of: analyticsEnabled) { _, newValue in
                        AnalyticsService.shared.setEnabled(newValue)
                    }

                    Text("settings.privacy.title".localized.uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .kerning(1.2)
                        .foregroundColor(Color.white.opacity(0.4))
                        .padding(.top, 10)

                    VStack(spacing: 0) {
                        linkRow(title: "profile.privacyPolicy".localized, url: privacyURL)
                        Divider().background(Color.white.opacity(0.06))
                        linkRow(title: "profile.termsOfUse".localized, url: termsURL)
                    }
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(20)
            }
            .background(Color.theme.background.ignoresSafeArea())
            .navigationTitle("profile.privacyTerms".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityLabel(Text("common.close".localized))
                }
            }
        }
    }

    private func linkRow(title: String, url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "6c6d73"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
        }
    }
}
