import SwiftUI

/// Redesign 2.0 — il banner dell'import sotto l'header di Scopri, nei tre stati del mockup:
/// in corso (percentuale REALE dai contatori delle fasi), completato con titoli da verificare
/// ("Gestisci"), completato pulito (verde, "OK"). Scompare quando non c'è niente da dire.
struct ImportStatusBanner: View {
    @ObservedObject var center: ImportStatusCenter

    var body: some View {
        switch center.banner {
        case .hidden:
            EmptyView()
        case .running(let fraction, let processed, let total):
            runningCard(fraction: fraction, processed: processed, total: total)
        case .review(let pending, let totalEpisodes):
            reviewCard(pending: pending, totalEpisodes: totalEpisodes)
        case .success(let serie, let episodi, let film):
            successCard(serie: serie, episodi: episodi, film: film)
        }
    }

    // MARK: In corso

    private func runningCard(fraction: Double, processed: Int?, total: Int?) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 2) {
                    Text("import.banner.running".localized)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                    if let processed, let total, total > 0 {
                        Text(String(format: "import.banner.episodes".localized,
                                    processed.formatted(), total.formatted()))
                            .font(.system(size: 12))
                            .foregroundColor(.theme.textSecondary)
                    }
                }
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.theme.accentOrange)
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(Color.theme.accentOrange)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.theme.accentOrange.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.theme.accentOrange.opacity(0.35), lineWidth: 1))
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.4), value: fraction)
    }

    // MARK: Completato, con inbox

    private func reviewCard(pending: Int, totalEpisodes: Int) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.theme.accentOrange.opacity(0.15))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.theme.accentOrange)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("import.banner.completed".localized)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                Text(String(format: "import.banner.review".localized,
                            pending, totalEpisodes.formatted()))
                    .font(.system(size: 12))
                    .foregroundColor(.theme.textSecondary)
            }
            Spacer()
            Button {
                center.showReviewSheet = true
            } label: {
                Text("import.banner.manage".localized)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color.theme.background)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.theme.accentOrange))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.theme.accentOrange.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: Completato, pulito

    private func successCard(serie: Int, episodi: Int, film: Int) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.green.opacity(0.9))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.black)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("import.banner.completed".localized)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                Text(String(format: "import.banner.summary".localized,
                            serie.formatted(), episodi.formatted(), film.formatted()))
                    .font(.system(size: 12))
                    .foregroundColor(.theme.textSecondary)
            }
            Spacer()
            Button {
                center.dismissSuccessBanner()
            } label: {
                Text("import.banner.ok".localized)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.green.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.green.opacity(0.35), lineWidth: 1))
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var badge: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(Color(hex: "f5c518"))
            .frame(width: 32, height: 32)
            .overlay(
                Text("tv:t")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(.black)
            )
    }
}
