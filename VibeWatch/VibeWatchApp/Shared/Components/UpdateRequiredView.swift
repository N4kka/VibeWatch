import SwiftUI

/// La schermata da cui non si esce finché non si aggiorna.
///
/// È l'unica cosa che l'utente vede: deve dire in un colpo d'occhio *cosa* sta succedendo (una
/// versione minima non più supportata), *da dove a dove* si sta andando e *cosa cambia* — e
/// rassicurare che la libreria non si tocca. Il vecchio schermo era un titolo, dei pallini e un
/// bottone in inglese hardcoded.
struct UpdateRequiredView: View {
    let requirement: UpdateRequirement

    @State private var showAllNotes = false

    /// Le prime tre note stanno nella card; il resto sta dietro la riga espandibile.
    private static let visibleNotes = 3

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var targetVersion: String? {
        requirement.latestVersion ?? (requirement.minimumVersion.isEmpty ? nil : requirement.minimumVersion)
    }

    private var extraNotes: [String] {
        Array(requirement.releaseNotes.dropFirst(Self.visibleNotes))
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color.theme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    badge
                    appMark
                    versionJump
                    titleBlock

                    if !requirement.releaseNotes.isEmpty {
                        changesCard
                    }

                    cta
                    footer
                }
                .padding(.horizontal, 26)
                .padding(.top, 28)
                .padding(.bottom, 40)
            }
        }
        .interactiveDismissDisabled(true)
    }

    // MARK: - Pezzi

    private var badge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color.theme.accentOrange)
                .frame(width: 6, height: 6)
            Text("update.required".localized)
                .font(.system(size: 11.5, weight: .bold))
                .tracking(0.8)
                .foregroundColor(.theme.accentOrange)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().stroke(Color.theme.accentOrange.opacity(0.35), lineWidth: 1))
    }

    private var appMark: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.theme.accentOrange)
            .frame(width: 88, height: 88)
            .overlay(
                Image(systemName: "play.display")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundColor(.black)
            )
            .shadow(color: Color.theme.accentOrange.opacity(0.35), radius: 22, y: 10)
    }

    @ViewBuilder
    private var versionJump: some View {
        if let targetVersion {
            HStack(spacing: 10) {
                Text(currentVersion)
                    .strikethrough()
                    .foregroundColor(.theme.textSecondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.theme.textSecondary)
                Text(targetVersion)
                    .foregroundColor(.theme.textPrimary)
            }
            .font(.system(size: 14, weight: .bold))
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 10) {
            Text(requirement.title)
                .font(.system(size: 29, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .multilineTextAlignment(.center)

            if let message = requirement.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 15.5))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
    }

    private var changesCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("update.whatsChanged".localized)
                .font(.system(size: 11.5, weight: .bold))
                .tracking(0.9)
                .foregroundColor(.theme.textSecondary)

            ForEach(Array(requirement.releaseNotes.prefix(Self.visibleNotes).enumerated()), id: \.offset) { index, note in
                noteRow(note, index: index)
            }

            if !extraNotes.isEmpty {
                Divider().overlay(Color.white.opacity(0.08))

                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { showAllNotes.toggle() }
                } label: {
                    HStack {
                        Text("update.fullReleaseNotes".localized)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(.theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.theme.textSecondary)
                            .rotationEffect(.degrees(showAllNotes ? 180 : 0))
                    }
                }
                .buttonStyle(.plain)

                if showAllNotes {
                    ForEach(Array(extraNotes.enumerated()), id: \.offset) { index, note in
                        noteRow(note, index: index + Self.visibleNotes)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.065)))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    /// Le note di rilascio sono stringhe semplici: la prima riga fa da titolo, il resto da
    /// descrizione. Nessun campo nuovo nel JSON, nessuna migrazione del formato.
    private func noteRow(_ note: String, index: Int) -> some View {
        let lines = note.components(separatedBy: "\n")
        let heading = lines.first ?? note
        let body = lines.dropFirst().joined(separator: "\n")
        let icons = ["arrow.triangle.2.circlepath", "bell", "star", "sparkles"]

        return HStack(alignment: .top, spacing: 13) {
            Image(systemName: icons[index % icons.count])
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.theme.accentOrange)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.theme.accentOrange.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(heading)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if !body.isEmpty {
                    Text(body)
                        .font(.system(size: 13.5))
                        .foregroundColor(.theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var cta: some View {
        Button(action: openAppStore) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 16, weight: .bold))
                Text("update.cta".localized)
                    .font(.system(size: 17, weight: .bold))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Capsule().fill(Color.theme.accentOrange))
        }
        .padding(.top, 4)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let targetVersion {
                Text(String(format: "update.versionFootnote".localized, targetVersion))
                    .font(.system(size: 12.5))
                    .foregroundColor(.theme.textSecondary)
            }

            HStack(spacing: 7) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                Text("update.dataSafe".localized)
                    .font(.system(size: 12.5))
            }
            .foregroundColor(.theme.textSecondary)
            .multilineTextAlignment(.center)
        }
    }

    private func openAppStore() {
        guard let url = URL(string: requirement.appStoreURL) else { return }
        UIApplication.shared.open(url)
    }
}
