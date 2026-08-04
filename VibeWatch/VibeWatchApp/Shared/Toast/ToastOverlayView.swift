import SwiftUI

/// Root view of the toast window: one capsule at a time, anchored above the tab bar.
struct ToastOverlayView: View {
    @EnvironmentObject private var center: ToastCenter

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let toast = center.current {
                ToastCapsule(toast: toast)
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: center.current)
        .allowsHitTesting(false)
    }
}

/// Testo sopra, avanzamento sotto: una rotella accanto a una frase non dice "sto lavorando",
/// una barra sì — e resta la stessa forma quando l'operazione finisce, piena o rossa.
struct ToastCapsule: View {
    let toast: ToastCenter.Toast

    /// Fa scorrere la barra indeterminata mentre l'operazione è in corso.
    @State private var sliding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                icon
                Text(toast.message)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            progressBar
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .frame(minHeight: 56)
        .background(.ultraThinMaterial)
        .background(Color(hex: "202126").opacity(0.94))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var icon: some View {
        switch toast.phase {
        case .progress:
            EmptyView()
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.theme.accentOrange)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))

                Capsule()
                    .fill(barColor)
                    .frame(width: barWidth(in: proxy.size.width))
                    .offset(x: barOffset(in: proxy.size.width))
            }
            .clipShape(Capsule())
        }
        .frame(height: 3)
        .onAppear { startSlidingIfNeeded() }
        .onChange(of: toast.phase) { _, _ in startSlidingIfNeeded() }
    }

    private var barColor: Color {
        switch toast.phase {
        case .progress, .success: return .theme.accentOrange
        case .failure: return .red
        }
    }

    /// In corso la barra è un frammento che va e viene; conclusa, è piena.
    private func barWidth(in total: CGFloat) -> CGFloat {
        toast.phase == .progress ? total * 0.4 : total
    }

    private func barOffset(in total: CGFloat) -> CGFloat {
        guard toast.phase == .progress else { return 0 }
        return sliding ? total * 0.6 : 0
    }

    private func startSlidingIfNeeded() {
        guard toast.phase == .progress else {
            sliding = false
            return
        }
        sliding = false
        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
            sliding = true
        }
    }
}
