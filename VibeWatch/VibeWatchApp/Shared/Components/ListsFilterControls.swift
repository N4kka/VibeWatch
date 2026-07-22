import SwiftUI

/// Shared controls for the Lists filter row: a collapsible search toggle and the "Filtri"
/// button with an active-count badge. Used by both the Lists landing and custom-list detail
/// so the two screens stay visually identical.
enum ListsFilterRow {
    /// Circular icon button that reveals/hides the inline "search this list" field.
    @ViewBuilder
    static func searchToggle(isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(isOn ? .theme.accentOrange : .theme.textPrimary)
                .frame(width: 42, height: 42)
                .background(isOn ? Color.theme.accentOrange.opacity(0.14) : Color.white.opacity(0.1))
                .clipShape(Circle())
        }
    }

    /// The single door to `GlobalFilterView`, showing the number of active filters as a badge.
    @ViewBuilder
    static func filtersButton(count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14))
                Text("filters.title".localized)
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(.theme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.1))
            .clipShape(Capsule())
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 18, height: 18)
                        .background(Color.theme.accentOrange)
                        .clipShape(Circle())
                        .offset(x: 6, y: -6)
                }
            }
        }
    }
}
