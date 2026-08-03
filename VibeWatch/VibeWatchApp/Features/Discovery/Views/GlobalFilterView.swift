import SwiftUI

/// Bottom sheet used by the whole Discovery surface. The compact controls mirror the
/// discovery redesign while the data still maps to `GlobalDiscoveryFilters`.
struct GlobalFilterView: View {
    @Binding var filters: GlobalDiscoveryFilters
    @Binding var isPresented: Bool
    @EnvironmentObject private var quotaManager: DailyQuotaManager
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @AppStorage("selectedPlatforms") private var selectedPlatformsData: Data = Data()

    let onApply: (GlobalDiscoveryFilters) -> Void

    @State private var tempFilters: GlobalDiscoveryFilters
    @State private var showProUpgrade = false
    @State private var countryExpanded = false
    @State private var usesMyPlatforms: Bool

    init(
        filters: Binding<GlobalDiscoveryFilters>,
        isPresented: Binding<Bool>,
        onApply: @escaping (GlobalDiscoveryFilters) -> Void
    ) {
        self._filters = filters
        self._isPresented = isPresented
        self.onApply = onApply
        let current = filters.wrappedValue
        self._tempFilters = State(initialValue: current)
        self._usesMyPlatforms = State(initialValue: !current.streamingPlatforms.isEmpty)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.58)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            sheet
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .sheet(isPresented: $showProUpgrade) {
            ProPaywallView(isPresented: $showProUpgrade, source: "filters")
        }
    }

    private var sheet: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 42, height: 5)
                .padding(.top, 10)

            header

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 25) {
                    mediaTypeSection
                    sortSection
                    platformsSection
                    releasePeriodSection
                    runtimeSection
                    ratingSection
                    countrySection

                    if quotaManager.isProUser {
                        advancedSection
                    } else {
                        proUpgradeCard
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }

            applyButton
        }
        .frame(maxHeight: UIScreen.main.bounds.height * 0.92)
        .background(Color(hex: "15161b"))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var header: some View {
        HStack {
            Text("filters.title".localized)
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(.theme.textPrimary)
            Spacer()
            Button("filters.reset".localized, action: resetFilters)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.theme.accentOrange)
            Button { isPresented = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.theme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 17)
    }

    // MARK: Main controls

    private var mediaTypeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("filters.mediaType".localized)
            HStack(spacing: 0) {
                ForEach(MediaTypeFilter.allCases) { type in
                    Button { tempFilters.mediaType = type } label: {
                        Text(type.displayName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(tempFilters.mediaType == type ? .white : .theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(tempFilters.mediaType == type ? Color.theme.accentOrange : .clear)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.white.opacity(0.07))
            .clipShape(Capsule())
        }
    }

    private var sortSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("filters.sortBy".localized)
            FlowLayout(spacing: 8) {
                ForEach(quotaManager.isProUser ? DiscoverySortOption.allCases : DiscoverySortOption.freeCases) { option in
                    FilterChip(title: option.displayName, isSelected: tempFilters.sortBy == option) {
                        tempFilters.sortBy = option
                    }
                }
            }
        }
    }

    private var platformsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("platforms.title".localized)
            HStack(spacing: 8) {
                scopeButton(title: "filters.myPlatforms".localized, selected: usesMyPlatforms) {
                    usesMyPlatforms = true
                    tempFilters.streamingPlatforms = Set(
                        PlatformSelectionCodec.decode(selectedPlatformsData).map(\.rawValue)
                    )
                }
                scopeButton(title: "filters.platformScopeAll".localized, selected: !usesMyPlatforms) {
                    usesMyPlatforms = false
                    tempFilters.streamingPlatforms.removeAll()
                }
            }
            Text("platforms.footnote".localized)
                .font(.system(size: 11.5))
                .foregroundColor(Color(hex: "797a80"))
        }
    }

    private var releasePeriodSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("filters.releasePeriod".localized)
            FlowLayout(spacing: 8) {
                ForEach(availableReleasePresets) { preset in
                    FilterChip(title: preset.displayName, isSelected: tempFilters.releasePeriodPreset == preset) {
                        tempFilters.releasePeriodPreset = preset
                    }
                }
            }
        }
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("filters.runtime".localized)
            FlowLayout(spacing: 8) {
                ForEach(availableRuntimePresets) { preset in
                    FilterChip(title: preset.displayName, isSelected: tempFilters.runtimePreset == preset) {
                        tempFilters.runtimePreset = preset
                    }
                }
            }
        }
    }

    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("filters.minimumRating".localized)
            FlowLayout(spacing: 8) {
                ForEach(availableRatingPresets) { preset in
                    FilterChip(title: preset.displayName, isSelected: tempFilters.ratingPreset == preset) {
                        tempFilters.ratingPreset = preset
                    }
                }
            }
        }
    }

    // MARK: Country accordion

    private var countrySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    countryExpanded.toggle()
                }
            } label: {
                HStack {
                    sectionTitle("filters.country".localized)
                    Spacer()
                    Text(countrySummary)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.theme.textSecondary)
                    Image(systemName: countryExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if countryExpanded {
                FlowLayout(spacing: 8) {
                    FilterChip(title: "filters.ratingAny".localized, isSelected: tempFilters.countries.isEmpty) {
                        tempFilters.countries.removeAll()
                    }
                    ForEach(Country.all) { country in
                        FilterChip(
                            title: countryDisplayName(country),
                            isSelected: tempFilters.countries.contains(country.id)
                        ) {
                            toggleCountry(country.id)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Pro

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 7) {
                sectionTitle("filters.proFilters".localized)
                Image(systemName: "crown.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.theme.accentOrange)
            }
            if tempFilters.runtimePreset == .custom {
                customIntRange(
                    title: "filters.runtime".localized,
                    from: $tempFilters.customRuntimeMin,
                    to: $tempFilters.customRuntimeMax
                )
            }
            if tempFilters.releasePeriodPreset == .custom {
                customIntRange(
                    title: "filters.customYearRange".localized,
                    from: $tempFilters.customYearStart,
                    to: $tempFilters.customYearEnd
                )
            }
            if tempFilters.ratingPreset == .custom {
                VStack(alignment: .leading, spacing: 7) {
                    Text("filters.rating".localized)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(.theme.textSecondary)
                    HStack(spacing: 9) {
                        numberField("filters.min".localized, value: $tempFilters.customRatingMin)
                        numberField("filters.max".localized, value: $tempFilters.customRatingMax)
                    }
                }
            }
            Toggle("filters.hideWatched".localized, isOn: $tempFilters.hideWatched)
            Toggle("filters.hideDisliked".localized, isOn: $tempFilters.hideDisliked)
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(.theme.textPrimary)
        .tint(.theme.accentOrange)
        .padding(16)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 17))
    }

    private var proUpgradeCard: some View {
        Button { showProUpgrade = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.theme.accentOrange)
                    .frame(width: 42, height: 42)
                    .background(Color.theme.accentOrange.opacity(0.14))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("filters.proTitle".localized)
                        .font(.system(size: 14.5, weight: .heavy))
                        .foregroundColor(.theme.textPrimary)
                    Text("filters.proDescription".localized)
                        .font(.system(size: 11.5))
                        .foregroundColor(.theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.theme.accentOrange)
            }
            .padding(15)
            .background(Color.theme.accentOrange.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 17)
                    .stroke(Color.theme.accentOrange.opacity(0.28), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private var applyButton: some View {
        Button(action: applyFilters) {
            Text("filters.apply".localized)
                .font(.system(size: 16, weight: .heavy))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.theme.accentOrange)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .background(Color(hex: "15161b"))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .heavy))
            .kerning(1.15)
            .foregroundColor(Color(hex: "818289"))
    }

    private func customIntRange(
        title: String,
        from: Binding<Int?>,
        to: Binding<Int?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundColor(.theme.textSecondary)
            HStack(spacing: 9) {
                numberField("filters.from".localized, value: from)
                numberField("filters.to".localized, value: to)
            }
        }
    }

    private func numberField(
        _ title: String,
        value: Binding<Int?>
    ) -> some View {
        TextField(title, value: value, format: .number)
            .keyboardType(.numberPad)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color.white.opacity(0.065))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func numberField(
        _ title: String,
        value: Binding<Double?>
    ) -> some View {
        TextField(title, value: value, format: .number)
            .keyboardType(.decimalPad)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color.white.opacity(0.065))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func scopeButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(selected ? .theme.accentOrange : .theme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(selected ? Color.theme.accentOrange.opacity(0.11) : Color.white.opacity(0.06))
                .overlay(Capsule().stroke(selected ? Color.theme.accentOrange : Color.white.opacity(0.1)))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var availableRuntimePresets: [RuntimePreset] {
        RuntimePreset.allCases.filter { quotaManager.isProUser || $0 != .custom }
    }

    private var availableRatingPresets: [RatingPreset] {
        RatingPreset.allCases.filter { quotaManager.isProUser || $0 != .custom }
    }

    private var availableReleasePresets: [ReleasePeriodPreset] {
        ReleasePeriodPreset.allCases.filter { quotaManager.isProUser || $0 != .custom }
    }

    private var countrySummary: String {
        guard !tempFilters.countries.isEmpty else { return "filters.ratingAny".localized }
        if tempFilters.countries.count == 1,
           let country = Country.findByCode(tempFilters.countries[0]) {
            return countryDisplayName(country)
        }
        return "\(tempFilters.countries.count)"
    }

    private func countryDisplayName(_ country: Country) -> String {
        Locale(identifier: localizationManager.currentLanguage.id)
            .localizedString(forRegionCode: country.id) ?? country.name
    }

    private func toggleCountry(_ code: String) {
        if tempFilters.countries.contains(code) {
            tempFilters.countries.removeAll { $0 == code }
        } else if quotaManager.isProUser {
            tempFilters.countries.append(code)
        } else {
            tempFilters.countries = [code]
        }
    }

    private func resetFilters() {
        tempFilters = GlobalDiscoveryFilters()
        usesMyPlatforms = false
    }

    private func applyFilters() {
        if !quotaManager.isProUser {
            tempFilters.customRuntimeMin = nil
            tempFilters.customRuntimeMax = nil
            tempFilters.customRatingMin = nil
            tempFilters.customRatingMax = nil
            tempFilters.customYearStart = nil
            tempFilters.customYearEnd = nil
            tempFilters.hideWatched = false
            tempFilters.hideDisliked = false
        }
        filters = tempFilters
        onApply(tempFilters)
        isPresented = false
    }
}

/// A chip owns its intrinsic width; `FlowLayout` moves the entire chip to the next line.
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(isSelected ? .theme.accentOrange : .theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 15)
                .frame(height: 42)
                .background(isSelected ? Color.theme.accentOrange.opacity(0.11) : Color.white.opacity(0.065))
                .overlay(
                    Capsule().stroke(
                        isSelected ? Color.theme.accentOrange : Color.white.opacity(0.1),
                        lineWidth: isSelected ? 1.2 : 1
                    )
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
