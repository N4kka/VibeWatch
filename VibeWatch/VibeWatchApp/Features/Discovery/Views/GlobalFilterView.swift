import SwiftUI

/// Global filter view that applies to ALL Discovery carousels
/// Differentiates between Free and Pro features
struct GlobalFilterView: View {
    @Binding var filters: GlobalDiscoveryFilters
    @Binding var isPresented: Bool
    @EnvironmentObject var quotaManager: DailyQuotaManager
    @ObservedObject var localizationManager = LocalizationManager.shared

    let onApply: (GlobalDiscoveryFilters) -> Void

    @State private var tempFilters: GlobalDiscoveryFilters
    @State private var showProUpgrade = false
    @State private var countrySearchQuery: String = ""

    init(
        filters: Binding<GlobalDiscoveryFilters>,
        isPresented: Binding<Bool>,
        onApply: @escaping (GlobalDiscoveryFilters) -> Void
    ) {
        self._filters = filters
        self._isPresented = isPresented
        self.onApply = onApply
        self._tempFilters = State(initialValue: filters.wrappedValue)
    }

    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }

            // Filter panel
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("filters.title".localized)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.theme.textPrimary)

                        Spacer()

                        Button(action: resetFilters) {
                            Text("filters.reset".localized)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.theme.accentOrange)
                        }

                        Button(action: { isPresented = false }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.theme.textSecondary)
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.1))
                                .clipShape(Circle())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(Color.theme.cardBackground)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 24) {
                            // Media Type Filter (FREE)
                            GlobalFilterSection(title: "filters.mediaType".localized, isPro: false) {
                                mediaTypeFilter
                            }

                            // Runtime Filter (FREE presets, PRO custom)
                            GlobalFilterSection(title: "filters.runtime".localized, isPro: false) {
                                runtimeFilter
                            }

                            // Rating Filter (FREE presets, PRO custom)
                            GlobalFilterSection(title: "filters.rating".localized, isPro: false) {
                                ratingFilter
                            }

                            // Release Period Filter (FREE presets, PRO custom)
                            GlobalFilterSection(title: "filters.releasePeriod".localized, isPro: false) {
                                releasePeriodFilter
                            }

                            // Country (Free: top 10, PRO all)
                            GlobalFilterSection(title: "filters.country".localized, isPro: false) {
                                countryFilter
                            }
                            
                            // Streaming Platforms (Available to all)
                            GlobalFilterSection(title: "platforms.title".localized, isPro: false) {
                                platformFilter
                            }

                            // Sort By (FREE basic, PRO advanced)
                            GlobalFilterSection(title: "filters.sortBy".localized, isPro: false) {
                                sortByFilter
                            }

                            // Pro Only Filters
                            if quotaManager.isProUser {
                                Divider()
                                    .background(Color.white.opacity(0.1))
                                    .padding(.vertical, 8)

                                GlobalFilterSection(title: "filters.proFilters".localized, isPro: true) {
                                    proOnlyFilters
                                }
                            } else {
                                // Pro Upgrade Card
                                proUpgradeCard
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 20)
                    }
                    .frame(maxHeight: UIScreen.main.bounds.height * 0.7)

                    // Apply Button
                    Button(action: applyFilters) {
                        Text("filters.apply".localized)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.theme.accentOrange)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .background(Color.theme.cardBackground)
                .cornerRadius(20, corners: [.topLeft, .topRight])
            }
            .transition(.move(edge: .bottom))
        }
        .sheet(isPresented: $showProUpgrade) {
            ProPaywallView(isPresented: $showProUpgrade, source: "filters")
        }
    }

    // MARK: - Media Type Filter

    private var mediaTypeFilter: some View {
        HStack(spacing: 12) {
            ForEach(MediaTypeFilter.allCases) { type in
                Button {
                    tempFilters.mediaType = type
                } label: {
                    Text(type.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(tempFilters.mediaType == type ? .white : .theme.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            tempFilters.mediaType == type ?
                            Color.theme.accentOrange :
                            Color.white.opacity(0.1)
                        )
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Runtime Filter

    private var runtimeFilter: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Free presets
            HStack(spacing: 12) {
                ForEach(RuntimePreset.allCases) { preset in
                    Button {
                        tempFilters.runtimePreset = preset
                        if !quotaManager.isProUser {
                            tempFilters.customRuntimeMin = nil
                            tempFilters.customRuntimeMax = nil
                        }
                    } label: {
                        Text(preset.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(tempFilters.runtimePreset == preset ? .white : .theme.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                tempFilters.runtimePreset == preset ?
                                Color.theme.accentOrange :
                                Color.white.opacity(0.1)
                            )
                            .clipShape(Capsule())
                    }
                }
            }

            // Pro custom range
            if quotaManager.isProUser {
                VStack(alignment: .leading, spacing: 8) {
                    Text("filters.customRange".localized)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.theme.textSecondary)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("filters.min".localized)
                                .font(.system(size: 10))
                                .foregroundColor(.theme.textSecondary)
                            TextField("0", value: $tempFilters.customRuntimeMin, format: .number)
                                .textFieldStyle(FilterTextFieldStyle())
                                .onChange(of: tempFilters.customRuntimeMin) { _, _ in
                                    tempFilters.runtimePreset = .custom
                                }
                        }

                        Text("-")
                            .foregroundColor(.theme.textSecondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("filters.max".localized)
                                .font(.system(size: 10))
                                .foregroundColor(.theme.textSecondary)
                            TextField("300", value: $tempFilters.customRuntimeMax, format: .number)
                                .textFieldStyle(FilterTextFieldStyle())
                                .onChange(of: tempFilters.customRuntimeMax) { _, _ in
                                    tempFilters.runtimePreset = .custom
                                }
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Rating Filter

    private var ratingFilter: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Free presets
            HStack(spacing: 12) {
                ForEach(RatingPreset.allCases) { preset in
                    Button {
                        tempFilters.ratingPreset = preset
                        if !quotaManager.isProUser {
                            tempFilters.customRatingMin = nil
                            tempFilters.customRatingMax = nil
                        }
                    } label: {
                        Text(preset.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(tempFilters.ratingPreset == preset ? .white : .theme.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                tempFilters.ratingPreset == preset ?
                                Color.theme.accentOrange :
                                Color.white.opacity(0.1)
                            )
                            .clipShape(Capsule())
                    }
                }
            }

            // Pro custom range
            if quotaManager.isProUser {
                VStack(alignment: .leading, spacing: 8) {
                    Text("filters.customRange".localized)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.theme.textSecondary)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("filters.min".localized)
                                .font(.system(size: 10))
                                .foregroundColor(.theme.textSecondary)
                            TextField("0.0", value: $tempFilters.customRatingMin, format: .number)
                                .textFieldStyle(FilterTextFieldStyle())
                                .onChange(of: tempFilters.customRatingMin) { _, _ in
                                    tempFilters.ratingPreset = .custom
                                }
                        }

                        Text("-")
                            .foregroundColor(.theme.textSecondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("filters.max".localized)
                                .font(.system(size: 10))
                                .foregroundColor(.theme.textSecondary)
                            TextField("10.0", value: $tempFilters.customRatingMax, format: .number)
                                .textFieldStyle(FilterTextFieldStyle())
                                .onChange(of: tempFilters.customRatingMax) { _, _ in
                                    tempFilters.ratingPreset = .custom
                                }
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Release Period Filter

    private var releasePeriodFilter: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Free presets
            HStack(spacing: 12) {
                ForEach(ReleasePeriodPreset.allCases.prefix(3)) { preset in
                    Button {
                        tempFilters.releasePeriodPreset = preset
                        if !quotaManager.isProUser {
                            tempFilters.customYearStart = nil
                            tempFilters.customYearEnd = nil
                        }
                    } label: {
                        Text(preset.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(tempFilters.releasePeriodPreset == preset ? .white : .theme.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                tempFilters.releasePeriodPreset == preset ?
                                Color.theme.accentOrange :
                                Color.white.opacity(0.1)
                            )
                            .clipShape(Capsule())
                    }
                }
            }

            // Pro custom year range
            if quotaManager.isProUser {
                VStack(alignment: .leading, spacing: 8) {
                    Text("filters.customYearRange".localized)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.theme.textSecondary)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("filters.from".localized)
                                .font(.system(size: 10))
                                .foregroundColor(.theme.textSecondary)
                            TextField("1900", value: $tempFilters.customYearStart, format: .number)
                                .textFieldStyle(FilterTextFieldStyle())
                                .onChange(of: tempFilters.customYearStart) { _, _ in
                                    tempFilters.releasePeriodPreset = .custom
                                }
                        }

                        Text("-")
                            .foregroundColor(.theme.textSecondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("filters.to".localized)
                                .font(.system(size: 10))
                                .foregroundColor(.theme.textSecondary)
                            TextField("2024", value: $tempFilters.customYearEnd, format: .number)
                                .textFieldStyle(FilterTextFieldStyle())
                                .onChange(of: tempFilters.customYearEnd) { _, _ in
                                    tempFilters.releasePeriodPreset = .custom
                                }
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Country Filter

    private var countryFilter: some View {
        Group {
            if quotaManager.isProUser {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.theme.textSecondary)

                        TextField("filters.searchCountry".localized, text: $countrySearchQuery)
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textPrimary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(10)

                    let filtered = CountryFilter.allCountries.filter { country in
                        if countrySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            return true
                        }
                        let q = countrySearchQuery.lowercased()
                        return country.name.lowercased().contains(q) || country.code.lowercased().contains(q)
                    }

                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(filtered, id: \.code) { country in
                                Button {
                                    if tempFilters.countries.contains(country.code) {
                                        tempFilters.countries.removeAll { $0 == country.code }
                                    } else {
                                        tempFilters.countries.append(country.code)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Text(country.flag)
                                        Text(country.name)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.theme.textPrimary)

                                        Spacer()

                                        if tempFilters.countries.contains(country.code) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.theme.accentOrange)
                                        } else {
                                            Image(systemName: "circle")
                                                .foregroundColor(.theme.textSecondary)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.06))
                                    .cornerRadius(10)
                                }
                            }

                            if !tempFilters.countries.isEmpty {
                                Button {
                                    tempFilters.countries = []
                                } label: {
                                    Text("filters.allCountries".localized)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.theme.accentOrange)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color.theme.accentOrange.opacity(0.08))
                                        .cornerRadius(10)
                                }
                                .padding(.top, 6)
                            }
                        }
                    }
                    .frame(height: 220)
                }
            } else {
                Menu {
                    ForEach(CountryFilter.topCountries, id: \.code) { country in
                        Button {
                            tempFilters.countries = [country.code]
                        } label: {
                            HStack {
                                Text(country.flag + " " + country.name)
                                if tempFilters.countries.first == country.code {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }

                    if !tempFilters.countries.isEmpty {
                        Divider()
                        Button {
                            tempFilters.countries = []
                        } label: {
                            Text("filters.allCountries".localized)
                        }
                    }
                } label: {
                    HStack {
                        if let first = tempFilters.countries.first,
                           let country = CountryFilter.find(by: first) {
                            Text(country.flag + " " + country.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.theme.textPrimary)
                        } else {
                            Text("filters.allCountries".localized)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.theme.textSecondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.theme.textSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(10)
                }
            }
        }
    }

    // MARK: - Platform Filter
    
    private var platformFilter: some View {
        VStack(spacing: 12) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
                    ForEach(StreamingPlatform.allCases) { platform in
                        Button {
                            if tempFilters.streamingPlatforms.contains(platform.rawValue) {
                                tempFilters.streamingPlatforms.remove(platform.rawValue)
                            } else {
                                tempFilters.streamingPlatforms.insert(platform.rawValue)
                            }
                        } label: {
                            VStack(spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.white.opacity(0.08))
                                        .frame(height: 50)
                                    
                                    if let logo = platform.logoAssetName {
                                        Image(logo)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(height: 30)
                                            .cornerRadius(6)
                                    } else {
                                        Image(systemName: platform.icon)
                                            .font(.system(size: 24))
                                            .foregroundColor(platform.color)
                                    }
                                    
                                    if tempFilters.streamingPlatforms.contains(platform.rawValue) {
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.theme.accentOrange, lineWidth: 2)
                                    }
                                }
                                
                                Text(platform.rawValue)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(tempFilters.streamingPlatforms.contains(platform.rawValue) ? .theme.accentOrange : .theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 180)
            
            if !tempFilters.streamingPlatforms.isEmpty {
                Button {
                    tempFilters.streamingPlatforms.removeAll()
                } label: {
                    Text("filters.allPlatforms".localized)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.accentOrange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.theme.accentOrange.opacity(0.08))
                        .cornerRadius(10)
                }
            }
        }
    }

    // MARK: - Sort By Filter

    private var sortByFilter: some View {
        VStack(spacing: 8) {
            ForEach(quotaManager.isProUser ? DiscoverySortOption.allCases : DiscoverySortOption.freeCases) { option in
                Button {
                    tempFilters.sortBy = option
                } label: {
                    HStack {
                        Text(option.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.theme.textPrimary)

                        Spacer()

                        if tempFilters.sortBy == option {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.theme.accentOrange)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        tempFilters.sortBy == option ?
                        Color.theme.accentOrange.opacity(0.2) :
                        Color.white.opacity(0.05)
                    )
                    .cornerRadius(10)
                }
            }
        }
    }

    // MARK: - Pro Only Filters

    private var proOnlyFilters: some View {
        VStack(spacing: 16) {
            // Hide Watched
            Toggle(isOn: $tempFilters.hideWatched) {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash.fill")
                        .foregroundColor(.theme.accentOrange)
                    Text("filters.hideWatched".localized)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.theme.textPrimary)
                }
            }
            .tint(.theme.accentOrange)

            // Hide Disliked
            Toggle(isOn: $tempFilters.hideDisliked) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.thumbsdown.fill")
                        .foregroundColor(.theme.accentOrange)
                    Text("filters.hideDisliked".localized)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.theme.textPrimary)
                }
            }
            .tint(.theme.accentOrange)
        }
    }

    // MARK: - Pro Upgrade Card

    private var proUpgradeCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "crown.fill")
                .font(.system(size: 32))
                .foregroundColor(.theme.accentOrange)

            Text("filters.proTitle".localized)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.theme.textPrimary)

            Text("filters.proDescription".localized)
                .font(.system(size: 13))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Button {
                showProUpgrade = true
            } label: {
                Text("filters.upgradeToPro".localized)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [Color.theme.accentOrange, Color.orange],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(10)
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color.theme.accentOrange.opacity(0.1), Color.orange.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.theme.accentOrange.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func resetFilters() {
        tempFilters = GlobalDiscoveryFilters()
    }

    private func applyFilters() {
        filters = tempFilters
        onApply(tempFilters)
        isPresented = false
    }
}

// MARK: - Filter Section Component

struct GlobalFilterSection<Content: View>: View {
    let title: String
    let isPro: Bool
    let content: Content

    init(title: String, isPro: Bool, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isPro = isPro
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)

                if isPro {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.theme.accentOrange)
                }
            }

            content
        }
    }
}

// MARK: - Custom TextField Style

struct FilterTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.1))
            .cornerRadius(8)
            .keyboardType(.numberPad)
    }
}
