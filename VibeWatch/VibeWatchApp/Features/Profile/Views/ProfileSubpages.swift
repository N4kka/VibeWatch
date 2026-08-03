import SwiftUI

// Redesign 2.0 — le due sottopagine del profilo che nel prototipo hanno una pagina propria
// e nell'app stavano annegate dentro Impostazioni: la cache immagini e privacy/termini.
// La pagina Impostazioni non è più esposta: queste sono le porte dirette dal profilo.

// MARK: - Cache immagini

struct ImageCacheSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ImageCacheService.shared.getCurrentCacheSizePreference()
    @State private var selectedPrefetch = ImageCacheService.shared.getCurrentImagePrefetchOption()
    @State private var diskUsageMB = 0
    @State private var showClearConfirm = false

    var body: some View {
        ZStack {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("settings.cacheManagement.cacheSizeDescription".localized)
                            .font(.system(size: 12.5))
                            .foregroundColor(.theme.textSecondary)
                            .padding(.horizontal, 4)

                        optionCard(ImageCacheService.CacheSizePreference.allCases, selected: selected) { option in
                            Text(option.rawValue)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(selected == option ? .theme.textPrimary : .theme.textSecondary)
                        } onSelect: { option in
                            selected = option
                            ImageCacheService.shared.setCacheSizePreference(option)
                        }

                        Text("settings.cacheManagement.prefetchTitle".localized.uppercased())
                            .font(.system(size: 11, weight: .heavy))
                            .kerning(1.2)
                            .foregroundColor(Color.white.opacity(0.4))
                            .padding(.horizontal, 4)
                            .padding(.top, 12)

                        Text("settings.cacheManagement.prefetchDescription".localized)
                            .font(.system(size: 12.5))
                            .foregroundColor(.theme.textSecondary)
                            .padding(.horizontal, 4)

                        optionCard(ImageCacheService.ImagePrefetchOption.allCases, selected: selectedPrefetch) { option in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.rawValue)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(selectedPrefetch == option ? .theme.textPrimary : .theme.textSecondary)
                                if option == .never {
                                    Text("settings.cacheManagement.prefetchNeverWarning".localized)
                                        .font(.system(size: 11))
                                        .foregroundColor(.theme.accentOrange)
                                }
                            }
                        } onSelect: { option in
                            selectedPrefetch = option
                            ImageCacheService.shared.setImagePrefetchOption(option)
                        }

                        Button { showClearConfirm = true } label: {
                            HStack {
                                Text("settings.cacheManagement.clearCache".localized)
                                    .font(.system(size: 13.5, weight: .bold))
                                    .foregroundColor(Color(hex: "ff5b5b"))
                                Spacer()
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
                        .padding(.top, 8)
                    }
                    .padding(20)
                }
                .background(Color.theme.background.ignoresSafeArea())
                .navigationTitle("profile.imageCache".localized)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        BackCircleButton { dismiss() }
                    }
                }
                .onAppear {
                    diskUsageMB = ImageCacheService.shared.getCacheStats().diskUsage / 1_048_576
                }
            }

            if showClearConfirm {
                popupOverlayBackground { showClearConfirm = false }
                ConfirmationPopup(
                    title: "settings.cacheManagement.clearCacheConfirmTitle".localized,
                    message: "settings.cacheManagement.clearCacheConfirmMessage".localized,
                    confirmTitle: "settings.cacheManagement.clearCacheAction".localized,
                    cancelTitle: "common.cancel".localized,
                    isDestructive: true,
                    onConfirm: {
                        ImageCacheService.shared.clearCache()
                        diskUsageMB = 0
                        showClearConfirm = false
                    },
                    onCancel: { showClearConfirm = false }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private func optionCard<Option: Hashable, Label: View>(
        _ options: [Option],
        selected: Option,
        @ViewBuilder label: @escaping (Option) -> Label,
        onSelect: @escaping (Option) -> Void
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                if index > 0 { Divider().background(Color.white.opacity(0.06)) }
                Button { onSelect(option) } label: {
                    HStack {
                        label(option)
                        Spacer()
                        if selected == option {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.theme.accentOrange)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Piattaforme

struct PlatformSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("selectedPlatforms") private var selectedPlatformsData: Data = Data()
    @State private var selectedPlatforms: Set<StreamingPlatform> = []

    private let sections: [(key: String, platforms: [StreamingPlatform])] = [
        ("platforms.streaming", [.netflix, .disney, .prime, .sky, .now, .apple]),
        ("platforms.rent", [.prime, .apple, .youtube, .plex]),
        ("platforms.buy", [.prime, .apple, .youtube])
    ]

    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                pageHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(sections, id: \.key) { section in
                            VStack(alignment: .leading, spacing: 14) {
                                Text(section.key.localized.uppercased())
                                    .font(.system(size: 11, weight: .heavy))
                                    .kerning(1.5)
                                    .foregroundColor(Color(hex: "77787f"))
                                FlowLayout(spacing: 10) {
                                    ForEach(section.platforms) { platform in platformChip(platform) }
                                }
                            }
                        }
                        Text("platforms.footnote".localized)
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(hex: "6f7076"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .padding(.bottom, 40)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { selectedPlatforms = PlatformSelectionCodec.decode(selectedPlatformsData) }
    }

    private var pageHeader: some View {
        ZStack {
            Text("platforms.title".localized)
                .font(.system(size: 21, weight: .heavy))
                .foregroundColor(.theme.textPrimary)
            HStack {
                BackCircleButton { dismiss() }
                Spacer()
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func platformChip(_ platform: StreamingPlatform) -> some View {
        let isSelected = selectedPlatforms.contains(platform)
        return Button {
            if isSelected { selectedPlatforms.remove(platform) }
            else { selectedPlatforms.insert(platform) }
            if let encoded = try? PlatformSelectionCodec.encode(selectedPlatforms) {
                selectedPlatformsData = encoded
            }
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(platform.color)
                    .frame(width: 24, height: 24)
                Text(platform.rawValue)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
            }
            .padding(.horizontal, 13)
            .frame(height: 46)
            .background(Color.white.opacity(0.055))
            .overlay(
                Capsule().stroke(
                    isSelected ? Color.theme.accentOrange : Color.white.opacity(0.12),
                    lineWidth: isSelected ? 1.4 : 1
                )
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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
                    BackCircleButton { dismiss() }
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
