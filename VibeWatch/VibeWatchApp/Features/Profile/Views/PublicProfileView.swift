import SwiftUI

/// SPEC v3 §9.3 — il profilo di un altro utente, versione blocco 8.
///
/// Header con avatar, nome, @username, bio e contatori, più il pulsante segui/seguito. Favorites,
/// stats e diario sono §9.3 pieno e arrivano col blocco 9: la struttura è già una destinazione
/// (`/@{username}` la aggancerà con gli universal links del blocco 10).
struct PublicProfileView: View {
    @StateObject private var viewModel: PublicProfileViewModel

    init(username: String) {
        _viewModel = StateObject(wrappedValue: PublicProfileViewModel(username: username))
    }

    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("@\(viewModel.username)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadProfile() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView()
        case .notFound:
            message(icon: "person.slash", textKey: "social.profile.notFound")
        case .failed:
            VStack(spacing: 12) {
                message(icon: "wifi.exclamationmark", textKey: "social.profile.loadFailed")
                Button("common.retry".localized) {
                    Task { await viewModel.loadProfile() }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.theme.accentOrange)
            }
        case .loaded(let detail):
            ScrollView {
                VStack(spacing: 20) {
                    header(detail)
                    counters(detail)
                    followButton(detail)
                    if let bio = detail.profile.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                    }
                }
                .padding(.vertical, 24)
            }
        }
    }

    private func header(_ detail: PublicProfileDetail) -> some View {
        VStack(spacing: 10) {
            avatar(detail.profile)
            VStack(spacing: 3) {
                Text(detail.profile.displayName ?? detail.profile.username)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                HStack(spacing: 6) {
                    Text("@\(detail.profile.username)")
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                    if detail.followsMe {
                        Text("social.followsYou".localized)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.theme.textSecondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private func counters(_ detail: PublicProfileDetail) -> some View {
        HStack(spacing: 32) {
            counter(value: detail.followers, labelKey: "social.profile.followers")
            counter(value: detail.following, labelKey: "social.profile.following")
        }
    }

    private func counter(value: Int, labelKey: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            Text(labelKey.localized)
                .font(.system(size: 12))
                .foregroundColor(.theme.textSecondary)
        }
    }

    /// Un'azione per volta e stato in volo visibile: fra il tap e i contatori aggiornati c'è un
    /// giro di rete, e un pulsante muto invita a premere di nuovo (imparato col segno di spunta
    /// del tracking).
    private func followButton(_ detail: PublicProfileDetail) -> some View {
        Button {
            Task { await viewModel.toggleFollow() }
        } label: {
            Group {
                if viewModel.isTogglingFollow {
                    ProgressView().tint(detail.isFollowing ? .white : .black)
                } else {
                    Text((detail.isFollowing ? "social.unfollow" : "social.follow").localized)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .frame(width: 180, height: 40)
            .foregroundColor(detail.isFollowing ? .theme.textPrimary : .black)
            .background(detail.isFollowing ? Color.white.opacity(0.1) : Color.theme.accentOrange)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(detail.isFollowing ? Color.white.opacity(0.2) : .clear, lineWidth: 1)
            )
        }
        .disabled(viewModel.isTogglingFollow)
    }

    private func avatar(_ profile: PublicProfile) -> some View {
        Group {
            if let urlString = profile.avatarUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    avatarPlaceholder(profile)
                }
            } else {
                avatarPlaceholder(profile)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(Circle())
    }

    private func avatarPlaceholder(_ profile: PublicProfile) -> some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            Text(String(profile.username.prefix(1)).uppercased())
                .font(.system(size: 36, weight: .semibold))
                .foregroundColor(.theme.textSecondary)
        }
    }

    private func message(icon: String, textKey: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundColor(.theme.textSecondary.opacity(0.6))
            Text(textKey.localized)
                .font(.system(size: 14))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }
}
