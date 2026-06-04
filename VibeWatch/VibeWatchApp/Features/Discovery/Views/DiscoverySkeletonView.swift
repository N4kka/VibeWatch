import SwiftUI

// MARK: - Shimmer Modifier

/// A reusable shimmer effect that sweeps a soft highlight across a placeholder shape,
/// matching the loading style used elsewhere in the app (see SkeletonClipCard).
struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.white.opacity(0.12),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 0.4)
                    .offset(x: phase * geometry.size.width * 1.4)
                }
                .allowsHitTesting(false)
            }
            .clipped()
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    /// Applies an animated shimmer overlay, used for skeleton placeholders.
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - Skeleton Building Blocks

private struct SkeletonBlock: View {
    var cornerRadius: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.08))
    }
}

/// A single placeholder poster card mirroring `MediaCard`'s layout.
private struct SkeletonMediaCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBlock(cornerRadius: 12)
                .frame(width: 140, height: 210)

            SkeletonBlock(cornerRadius: 4)
                .frame(width: 120, height: 14)

            SkeletonBlock(cornerRadius: 4)
                .frame(width: 60, height: 12)
        }
    }
}

/// A placeholder horizontal carousel mirroring `MediaSection`'s layout.
private struct SkeletonCarouselSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBlock(cornerRadius: 6)
                .frame(width: 180, height: 22)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        SkeletonMediaCard()
                    }
                }
                .padding(.horizontal, 20)
            }
            .disabled(true)
        }
    }
}

/// A placeholder hero card mirroring `MoodCarouselSection`'s layout.
private struct SkeletonHeroSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SkeletonBlock(cornerRadius: 6)
                .frame(width: 200, height: 26)
                .padding(.horizontal, 20)

            SkeletonBlock(cornerRadius: 20)
                .frame(height: 500)
                .padding(.horizontal, 20)
        }
    }
}

// MARK: - Discovery Skeleton

/// Instagram-style skeleton placeholder shown while Discovery carousels load on a
/// cold start (no cached content yet). The whole screen shimmers until real content
/// is ready, instead of a bare spinner.
struct DiscoverySkeletonView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                SkeletonHeroSection()

                ForEach(0..<4, id: \.self) { _ in
                    SkeletonCarouselSection()
                }

                Color.clear.frame(height: 80)
            }
            .padding(.top, 4)
        }
        .scrollDisabled(true)
        .shimmering()
        .background(Color.theme.background.ignoresSafeArea())
        .accessibilityLabel("Loading content")
    }
}

#Preview {
    DiscoverySkeletonView()
}
