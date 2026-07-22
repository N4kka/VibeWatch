import SwiftUI

struct AppHeaderView: View {
    let onSearchTap: () -> Void
    /// Optional: when nil, the filter button is hidden entirely (e.g. the Lists tab, which has
    /// its own inline Filtri control and shouldn't show a second door to the same sheet).
    var onFilterTap: (() -> Void)? = nil
    let onProfileTap: () -> Void
    let avatarURL: String?
    let isProUser: Bool
    var activeFilterCount: Int = 0

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image("logo_56x56")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.theme.accentOrange)

                Text("discovery.vibeWatch".localized)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .layoutPriority(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer()

            HStack(spacing: 12) {
                Button(action: onSearchTap) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.theme.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }

                if let onFilterTap {
                    Button(action: onFilterTap) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.theme.textPrimary)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                            .overlay(alignment: .topTrailing) {
                                if activeFilterCount > 0 {
                                    Text("\(activeFilterCount)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 18, height: 18)
                                        .background(Color.theme.accentOrange)
                                        .clipShape(Circle())
                                        .offset(x: 4, y: -4)
                                }
                            }
                    }
                }

                ProUpgradeIconButton(isProUser: isProUser, source: "app_header")

                Button(action: onProfileTap) {
                    if let avatarURL = avatarURL, let url = URL(string: avatarURL) {
                        CachedAsyncImage(url: url, maxPixelSize: 120) { image in
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 32, height: 32)
                                .clipShape(Circle())
                        } placeholder: {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.theme.textSecondary)
                        }
                    } else {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.theme.textSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            Color.theme.navigationBackground
                .ignoresSafeArea()
                .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
        }
    }
}
