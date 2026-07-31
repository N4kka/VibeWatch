import SwiftUI

/// SPEC v3 §3.7 — la ricerca utenti.
///
/// Tre stati che non si somigliano: l'invito (nessuna query), "nessuno trovato" (query vera,
/// zero righe) e "la ricerca è fallita" (errore di rete, con riprova). Il terzo esiste come
/// stato suo: mostrarlo come lista vuota sarebbe il fallimento silenzioso di sempre.
struct UserSearchView: View {
    @StateObject private var viewModel = UserSearchViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.theme.background.ignoresSafeArea()

                VStack(spacing: 16) {
                    searchField
                    content
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)
            }
            .navigationTitle("social.search.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("profile.done".localized) { dismiss() }
                        .foregroundColor(.theme.textPrimary)
                }
            }
            .navigationDestination(for: PublicProfile.self) { profile in
                PublicProfileView(username: profile.username)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.theme.textSecondary)
            TextField("social.search.placeholder".localized, text: $viewModel.query)
                .font(.system(size: 16))
                .foregroundColor(.theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            hint(icon: "person.2", textKey: "social.search.prompt")
        case .searching:
            ProgressView().padding(.top, 32)
        case .empty:
            hint(icon: "person.fill.questionmark", textKey: "social.search.noResults")
        case .failed:
            VStack(spacing: 12) {
                hint(icon: "wifi.exclamationmark", textKey: "social.search.failed")
                Button("common.retry".localized) {
                    // Rilancia la stessa query: il didSet riparte da capo.
                    let q = viewModel.query
                    viewModel.query = q
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.theme.accentOrange)
            }
        case .results(let profiles):
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(profiles) { profile in
                        NavigationLink(value: profile) {
                            UserSearchRow(profile: profile)
                        }
                        .buttonStyle(.plain)
                        if profile.id != profiles.last?.id {
                            Divider().background(Color.white.opacity(0.1))
                                .padding(.leading, 72)
                        }
                    }
                }
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
            }
        }
    }

    private func hint(icon: String, textKey: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundColor(.theme.textSecondary.opacity(0.6))
            Text(textKey.localized)
                .font(.system(size: 14))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
        .padding(.horizontal, 32)
    }
}

/// Una riga: avatar, nome, @username. Niente pulsante follow qui — la relazione si vede e si
/// cambia nel profilo, dove ci sono anche i numeri per capirla.
struct UserSearchRow: View {
    let profile: PublicProfile

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName ?? profile.username)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(1)
                Text("@\(profile.username)")
                    .font(.system(size: 13))
                    .foregroundColor(.theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.theme.textSecondary.opacity(0.5))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var avatar: some View {
        Group {
            if let urlString = profile.avatarUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    avatarPlaceholder
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            Text(String(profile.username.prefix(1)).uppercased())
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.theme.textSecondary)
        }
    }
}

extension PublicProfile: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
