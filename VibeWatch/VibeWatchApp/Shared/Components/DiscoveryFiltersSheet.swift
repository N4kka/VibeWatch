import SwiftUI

/// Unified Advanced Filters Panel - Works for both Discovery and Lists views
struct AdvancedFiltersPanel: View {
    @Binding var filters: DiscoveryFilters
    let showRuntimeFilter: Bool // Only for movies in Discovery
    let onDismiss: () -> Void
    let onApply: (DiscoveryFilters) -> Void
    @EnvironmentObject var quotaManager: DailyQuotaManager
    
    init(
        filters: Binding<DiscoveryFilters>,
        showRuntimeFilter: Bool = true,
        onDismiss: @escaping () -> Void,
        onApply: @escaping (DiscoveryFilters) -> Void
    ) {
        self._filters = filters
        self.showRuntimeFilter = showRuntimeFilter
        self.onDismiss = onDismiss
        self.onApply = onApply
    }
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }
            
            VStack(spacing: 0) {
                Spacer()
                
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("filters.title".localized)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.theme.textPrimary)
                        
                        Spacer()
                        
                        Button {
                            onApply(filters)
                            onDismiss()
                        } label: {
                            Text("filters.apply".localized)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.theme.accentOrange)
                                .clipShape(Capsule())
                        }
                        
                        Button {
                            filters = DiscoveryFilters()
                        } label: {
                            Text("filters.reset".localized)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.theme.accentOrange)
                                .clipShape(Capsule())
                        }
                        .padding(.leading, 8)
                        
                        Button {
                            onDismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.theme.textSecondary)
                        }
                        .padding(.leading, 12)
                    }
                    .padding(20)
                    
                    Divider()
                        .background(Color.white.opacity(0.1))
                    
                    // Content
                    ScrollView {
                        VStack(spacing: 24) {
                            // Sort By Filter
                            FilterSection(title: "filters.sortBy".localized) {
                                VStack(spacing: 8) {
                                    ForEach(DiscoverySortOption.allCases) { option in
                                        FilterOptionButton(
                                            title: option.displayName,
                                            isSelected: filters.sortBy == option
                                        ) {
                                            filters.sortBy = option
                                        }
                                    }
                                }
                            }
                            
                            // Runtime Filter (Movies only)
                            if showRuntimeFilter {
                                FilterSection(title: "filters.runtime".localized) {
                                    VStack(spacing: 8) {
                                        ForEach(RuntimeRange.allCases) { range in
                                            FilterOptionButton(
                                                title: range.displayName,
                                                isSelected: filters.runtimeRange == range
                                            ) {
                                                filters.runtimeRange = range
                                            }
                                        }
                                    }
                                }
                                .modifier(ProFeatureLocker(isPro: quotaManager.isProUser))
                            }
                            
                            // Rating Filter
                            FilterSection(title: "filters.minimumRating".localized) {
                                VStack(spacing: 8) {
                                    ForEach(RatingRange.allCases) { range in
                                        FilterOptionButton(
                                            title: range.displayName,
                                            isSelected: filters.ratingRange == range
                                        ) {
                                            filters.ratingRange = range
                                        }
                                    }
                                }
                            }
                            .modifier(ProFeatureLocker(isPro: quotaManager.isProUser))
                            
                            // Country Filter
                            FilterSection(title: "filters.country".localized) {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        CountryChip(
                                            name: "filters.anyCountry".localized,
                                            flag: "🌍",
                                            isSelected: filters.country == nil
                                        ) {
                                            filters.country = nil
                                        }
                                        
                                        ForEach(popularCountries, id: \.id) { country in
                                            CountryChip(
                                                name: country.name,
                                                flag: country.flag,
                                                isSelected: filters.country == country.id
                                            ) {
                                                filters.country = country.id
                                            }
                                        }
                                    }
                                } // Removed padding(.horizontal, 20) and padding(.horizontal, -20)
                            }
                            .modifier(ProFeatureLocker(isPro: quotaManager.isProUser))
                        }
                        .padding(20)
                        .padding(.bottom, 80) // Extra padding at bottom
                    }
                    .frame(maxHeight: UIScreen.main.bounds.height * 0.6)
                }
                .background(Color.theme.backgroundDark.opacity(0.98))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .padding(.bottom, 0)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    
    private var popularCountries: [Country] {
        [
            Country(id: "US", name: "USA", flag: "🇺🇸", nativeLanguageCode: "en"),
            Country(id: "GB", name: "UK", flag: "🇬🇧", nativeLanguageCode: "en"),
            Country(id: "IT", name: "Italy", flag: "🇮🇹", nativeLanguageCode: "it"),
            Country(id: "FR", name: "France", flag: "🇫🇷", nativeLanguageCode: "fr"),
            Country(id: "DE", name: "Germany", flag: "🇩🇪", nativeLanguageCode: "de"),
            Country(id: "ES", name: "Spain", flag: "🇪🇸", nativeLanguageCode: "es"),
            Country(id: "JP", name: "Japan", flag: "🇯🇵", nativeLanguageCode: "ja"),
            Country(id: "KR", name: "Korea", flag: "🇰🇷", nativeLanguageCode: "ko"),
            Country(id: "IN", name: "India", flag: "🇮🇳", nativeLanguageCode: "hi"),
            Country(id: "BR", name: "Brazil", flag: "🇧🇷", nativeLanguageCode: "pt"),
            Country(id: "MX", name: "Mexico", flag: "🇲🇽", nativeLanguageCode: "es"),
            Country(id: "CA", name: "Canada", flag: "🇨🇦", nativeLanguageCode: "en"),
            Country(id: "AU", name: "Australia", flag: "🇦🇺", nativeLanguageCode: "en")
        ]
    }
}

// MARK: - Sheet Version (for DiscoveryView)
struct DiscoveryFiltersSheet: View {
    @Environment(\.dismiss) var dismiss
    @Binding var filters: DiscoveryFilters
    @State private var localFilters: DiscoveryFilters
    @ObservedObject var localizationManager = LocalizationManager.shared
    @EnvironmentObject var quotaManager: DailyQuotaManager
    let onApply: (DiscoveryFilters) -> Void
    
    init(filters: Binding<DiscoveryFilters>, onApply: @escaping (DiscoveryFilters) -> Void) {
        self._filters = filters
        self._localFilters = State(initialValue: filters.wrappedValue)
        self.onApply = onApply
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Sort By Filter
                    FilterSection(title: "filters.sortBy".localized) {
                        VStack(spacing: 12) {
                            ForEach(DiscoverySortOption.allCases) { option in
                                FilterOptionButton(
                                    title: option.displayName,
                                    isSelected: localFilters.sortBy == option
                                ) {
                                    localFilters.sortBy = option
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    
                    // Runtime Filter (Movies only)
                    FilterSection(title: "filters.runtime".localized) {
                        VStack(spacing: 12) {
                            ForEach(RuntimeRange.allCases) { range in
                                FilterOptionButton(
                                    title: range.displayName,
                                    isSelected: localFilters.runtimeRange == range
                                ) {
                                    localFilters.runtimeRange = range
                                }
                            }
                        }
                    }
                    .modifier(ProFeatureLocker(isPro: quotaManager.isProUser))
                    .padding(.horizontal, 20)
                    
                    // Rating Filter
                    FilterSection(title: "filters.minimumRating".localized) {
                        VStack(spacing: 12) {
                            ForEach(RatingRange.allCases) { range in
                                FilterOptionButton(
                                    title: range.displayName,
                                    isSelected: localFilters.ratingRange == range
                                ) {
                                    localFilters.ratingRange = range
                                }
                            }
                        }
                    }
                    .modifier(ProFeatureLocker(isPro: quotaManager.isProUser))
                    .padding(.horizontal, 20)
                    
                    // Country Filter
                    FilterSection(title: "filters.country".localized) {
                        VStack(spacing: 12) {
                            FilterOptionButton(
                                title: "filters.anyCountry".localized,
                                isSelected: localFilters.country == nil
                            ) {
                                localFilters.country = nil
                            }
                            
                            ForEach(popularCountries, id: \.id) { country in
                                FilterOptionButton(
                                    title: "\(country.flag) \(country.name)",
                                    isSelected: localFilters.country == country.id
                                ) {
                                    localFilters.country = country.id
                                }
                            }
                        }
                    }
                    .modifier(ProFeatureLocker(isPro: quotaManager.isProUser))
                    .padding(.horizontal, 20)
            }
            .padding(.vertical, 40)
            }
            .background(Color.theme.background)
            .navigationTitle("filters.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("filters.reset".localized) {
                        localFilters = DiscoveryFilters()
                    }
                    .foregroundColor(.theme.accentOrange)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("filters.apply".localized) {
                        filters = localFilters
                        onApply(localFilters)
                        dismiss()
                    }
                    .foregroundColor(.theme.accentOrange)
                    .fontWeight(.semibold)
                }
            }
        }
    }
    
    private var popularCountries: [Country] {
        [
            Country(id: "US", name: "United States", flag: "🇺🇸", nativeLanguageCode: "en"),
            Country(id: "GB", name: "United Kingdom", flag: "🇬🇧", nativeLanguageCode: "en"),
            Country(id: "IT", name: "Italy", flag: "🇮🇹", nativeLanguageCode: "it"),
            Country(id: "FR", name: "France", flag: "🇫🇷", nativeLanguageCode: "fr"),
            Country(id: "DE", name: "Germany", flag: "🇩🇪", nativeLanguageCode: "de"),
            Country(id: "ES", name: "Spain", flag: "🇪🇸", nativeLanguageCode: "es"),
            Country(id: "JP", name: "Japan", flag: "🇯🇵", nativeLanguageCode: "ja"),
            Country(id: "KR", name: "South Korea", flag: "🇰🇷", nativeLanguageCode: "ko"),
            Country(id: "IN", name: "India", flag: "🇮🇳", nativeLanguageCode: "hi"),
            Country(id: "BR", name: "Brazil", flag: "🇧🇷", nativeLanguageCode: "pt"),
            Country(id: "MX", name: "Mexico", flag: "🇲🇽", nativeLanguageCode: "es"),
            Country(id: "CA", name: "Canada", flag: "🇨🇦", nativeLanguageCode: "en"),
            Country(id: "AU", name: "Australia", flag: "🇦🇺", nativeLanguageCode: "en")
        ]
    }
}

struct ProFeatureLocker: ViewModifier {
    let isPro: Bool

    func body(content: Content) -> some View {
        ZStack {
            content
                .disabled(!isPro)
                .blur(radius: isPro ? 0 : 3)

            if !isPro {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                    Text("common.pro".localized)
                        .font(.system(size: 14, weight: .bold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.7))
                .cornerRadius(8)
                .foregroundColor(.yellow)
            }
        }
    }
}

struct FilterSection<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
            
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FilterOptionButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : .theme.textPrimary)
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.theme.accentOrange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                isSelected ?
                Color.theme.accentOrange.opacity(0.3) :
                Color.white.opacity(0.05)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct CountryChip: View {
    let name: String
    let flag: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(flag)
                    .font(.system(size: 28))
                
                Text(name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .white : .theme.textPrimary)
                    .lineLimit(1)
            }
            .frame(width: 70, height: 70)
            .background(
                isSelected ?
                Color.theme.accentOrange.opacity(0.3) :
                Color.white.opacity(0.05)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.theme.accentOrange : Color.clear, lineWidth: 2)
            )
        }
    }
}

#Preview {
    DiscoveryFiltersSheet(filters: .constant(DiscoveryFilters())) { _ in }
}