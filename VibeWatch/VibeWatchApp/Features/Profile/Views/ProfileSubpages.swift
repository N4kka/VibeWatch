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

        }
        .sheet(isPresented: $showClearConfirm) {
            VWConfirmationSheet(
                title: "settings.cacheManagement.clearCacheConfirmTitle".localized,
                message: "settings.cacheManagement.clearCacheConfirmMessage".localized,
                confirmTitle: "settings.cacheManagement.clearCacheAction".localized,
                isDestructive: true,
                onConfirm: {
                    ImageCacheService.shared.clearCache()
                    diskUsageMB = 0
                    showClearConfirm = false
                },
                onCancel: { showClearConfirm = false }
            )
            .vwModalPresentation()
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

/// La schermata Piattaforme.
///
/// Prima erano chip con un quadrato colorato al posto del logo, divisi in tre sezioni statiche
/// scritte a mano. Ora: i loghi veri (gli stessi delle card), l'elenco che TMDB dà per il paese
/// dell'utente, quanti titoli della **sua** libreria stanno su ciascun servizio, e una barra che
/// dice quanto della watchlist gli abbonamenti scelti coprono davvero.
struct PlatformSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("selectedProviderIds") private var selectedProviderData: Data = Data()
    @AppStorage("selectedPlatforms") private var legacyPlatformsData: Data = Data()
    @AppStorage("selectedProviderNames") private var selectedProviderNamesData: Data = Data()
    @AppStorage("selectedProviderIds.migrated") private var didMigrateLegacySelection = false

    @StateObject private var viewModel = PlatformSelectionViewModel()
    @State private var selected: Set<Int> = []
    @State private var tier: PlatformSelectionViewModel.Tier = .streaming

    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                pageHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        summaryCard
                        tierPicker
                        Text("platforms.footnote".localized)
                            .font(.system(size: 12.5))
                            .foregroundColor(Color(hex: "6f7076"))
                            .fixedSize(horizontal: false, vertical: true)
                        providerRows
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 40)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            selected = ProviderSelectionCodec.decode(selectedProviderData)
            await viewModel.load(selected: selected)
            migrateLegacySelectionIfNeeded()
        }
    }

    // MARK: - Header

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
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Riepilogo

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selected.count)")
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundColor(.theme.textPrimary)
                    Text("platforms.active".localized)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }
                Spacer()
                if !selected.isEmpty {
                    Button {
                        selected = []
                        persist()
                    } label: {
                        Text("platforms.clear".localized)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.theme.textPrimary)
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }

            if !selectedProviders.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(selectedProviders) { provider in
                        HStack(spacing: 8) {
                            logo(for: provider, size: 22, corner: 6)
                            Text(provider.providerName)
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundColor(.theme.textPrimary)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 38)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                }
            }

            coverageBar
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private var coverageBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("platforms.coverage".localized)
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
                Spacer()
                // Senza abbastanza dati in cache la percentuale non si mostra: un numero
                // costruito su un terzo della watchlist direbbe una cosa falsa con precisione.
                if let coverage = viewModel.coverage {
                    Text("\(Int((coverage * 100).rounded()))%")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(.green)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(Color.green)
                        .frame(width: proxy.size.width * (viewModel.coverage ?? 0))
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Tab

    private var tierPicker: some View {
        HStack(spacing: 0) {
            ForEach(PlatformSelectionViewModel.Tier.allCases) { item in
                Button {
                    tier = item
                } label: {
                    VStack(spacing: 2) {
                        Text(item.titleKey.localized)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(tier == item ? .theme.accentOrange : .theme.textPrimary)
                        Text(String(format: "platforms.activeCount".localized,
                                    viewModel.activeCount(for: item, selected: selected)))
                            .font(.system(size: 12.5))
                            .foregroundColor(.theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(tier == item ? Color.theme.accentOrange.opacity(0.12) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(tier == item ? Color.theme.accentOrange.opacity(0.5) : Color.clear,
                                    lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.05)))
    }

    // MARK: - Righe

    @ViewBuilder
    private var providerRows: some View {
        let rows = viewModel.providers(for: tier, selected: selected)
        let recommended = viewModel.recommendedProviderId(selected: selected)

        if rows.isEmpty {
            HStack {
                Spacer()
                if viewModel.isLoading {
                    ProgressView()
                } else {
                    Text("platforms.empty".localized)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }
                Spacer()
            }
            .padding(.vertical, 40)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(rows) { provider in
                    providerRow(provider, isRecommended: provider.providerId == recommended)
                }
            }
        }
    }

    private func providerRow(_ provider: Provider, isRecommended: Bool) -> some View {
        let isSelected = selected.contains(provider.providerId)
        let count = viewModel.libraryCounts[provider.providerId] ?? 0

        return Button {
            if isSelected { selected.remove(provider.providerId) }
            else { selected.insert(provider.providerId) }
            persist()
        } label: {
            HStack(spacing: 14) {
                logo(for: provider, size: 46, corner: 11)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(provider.providerName)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.theme.textPrimary)
                            .lineLimit(1)

                        if isRecommended {
                            Text("platforms.recommended".localized)
                                .font(.system(size: 10, weight: .heavy))
                                .tracking(0.6)
                                .foregroundColor(.theme.accentOrange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.theme.accentOrange.opacity(0.16)))
                        }
                    }

                    if count > 0 {
                        Text(String(format: "platforms.libraryCount".localized, count))
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textSecondary)
                    }
                }

                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .fill(isSelected ? Color.theme.accentOrange : Color.clear)
                        .frame(width: 28, height: 28)
                    Circle()
                        .stroke(isSelected ? Color.clear : Color.white.opacity(0.25), lineWidth: 1.5)
                        .frame(width: 28, height: 28)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.black)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 17)
                    .fill(isSelected ? Color.theme.accentOrange.opacity(0.08) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 17)
                    .stroke(isSelected ? Color.theme.accentOrange.opacity(0.45) : Color.white.opacity(0.07),
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func logo(for provider: Provider, size: CGFloat, corner: CGFloat) -> some View {
        Group {
            if provider.hasUsableLogo {
                CachedAsyncImage(url: provider.logoURL, maxPixelSize: size * 3)
                    .aspectRatio(contentMode: .fit)
            } else {
                // Fallback: l'iniziale su fondo neutro. Meglio di un quadrato vuoto quando TMDB
                // dà un SVG (che `hasUsableLogo` scarta perché non lo sappiamo disegnare).
                ZStack {
                    Color.white.opacity(0.08)
                    Text(provider.providerName.prefix(1))
                        .font(.system(size: size * 0.45, weight: .heavy))
                        .foregroundColor(.theme.textPrimary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }

    // MARK: - Stato

    private var selectedProviders: [Provider] {
        viewModel.providers
            .filter { selected.contains($0.providerId) }
            .sorted { $0.displayPriority < $1.displayPriority }
    }

    private func persist() {
        selectedProviderData = ProviderSelectionCodec.encode(selected)
        // I nomi servono al filtro di disponibilità, che ragiona per nome e non per id.
        selectedProviderNamesData = ProviderSelectionCodec.encodeNames(
            Set(viewModel.providers.filter { selected.contains($0.providerId) }.map(\.providerName))
        )
        Task { await viewModel.refreshCoverage(selected: selected) }
    }

    /// Una volta sola: la vecchia selezione per nome diventa una selezione per provider_id.
    private func migrateLegacySelectionIfNeeded() {
        guard !didMigrateLegacySelection, selected.isEmpty else {
            didMigrateLegacySelection = true
            return
        }
        let legacy = PlatformSelectionCodec.decode(legacyPlatformsData)
        guard !legacy.isEmpty else {
            didMigrateLegacySelection = true
            return
        }
        let migrated = viewModel.migratedIds(from: legacy)
        guard !migrated.isEmpty else { return }   // niente catalogo ancora: si riprova al prossimo giro
        selected = migrated
        didMigrateLegacySelection = true
        persist()
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
