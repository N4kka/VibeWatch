import SwiftUI

struct SegmentedPicker<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 1)
                        .padding(.vertical, 8)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selection = item
                    }
                } label: {
                    Text(label(item))
                        .font(.system(size: 12, weight: selection == item ? .semibold : .medium))
                        .foregroundColor(selection == item ? Color.theme.accentOrange : .theme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.clear)
                }
            }
        }
        .fixedSize()
        .background(Color.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}
