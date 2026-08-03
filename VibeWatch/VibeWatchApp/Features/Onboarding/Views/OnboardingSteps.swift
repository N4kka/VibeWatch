import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tappa 1: Benvenuto

struct OnboardingWelcomeStep: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // La tessera "V" del prototipo: quadrato arancione con alone.
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(colors: [Color.theme.accentOrange, Color(hex: "e56a20")],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 88, height: 88)
                .overlay(
                    Text("V")
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundColor(Color.theme.background)
                )
                .shadow(color: Color.theme.accentOrange.opacity(0.45), radius: 28, x: 0, y: 0)
                .padding(.bottom, 28)

            VStack(spacing: 14) {
                Text("onboarding.welcome.title".localized)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text("onboarding.welcome.subtitle".localized)
                    .font(.system(size: 17))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)
            }

            Spacer()

            PrimaryButton(title: "onboarding.welcome.cta".localized) {
                viewModel.nextStep()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Tappa 2: Account

struct OnboardingAccountStep: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var showSignUp = false
    @State private var showSignIn = false
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            OnboardingHeroCircle(systemImage: "person.badge.plus")
                .padding(.bottom, 28)

            VStack(spacing: 14) {
                Text("onboarding.account.title".localized)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text("onboarding.account.subtitle".localized)
                    .font(.system(size: 16))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 18) {
                PrimaryButton(title: "auth.createAccount".localized) {
                    showSignUp = true
                }

                Button {
                    showSignIn = true
                } label: {
                    Text("auth.signIn".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showSignUp) {
            SignUpView()
                .environmentObject(appState)
                .environmentObject(authService)
        }
        .sheet(isPresented: $showSignIn) {
            SignInView()
                .environmentObject(appState)
                .environmentObject(authService)
        }
    }
}

// MARK: - Tappa 3: Import da TV Time

/// "Porta con te la tua storia". La schermata è un oblò sui medesimi stati di ImportView
/// (§7: lo stato vive sul server): sorgenti → upload → progresso → report. Qui il report è
/// la card verde con i quattro numeri, e "Continua" porta alla tappa notifiche.
struct OnboardingImportStep: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var importViewModel: ImportViewModel
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Text("onboarding.import.title".localized)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text("onboarding.import.subtitle".localized)
                    .font(.system(size: 16))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)
            }
            .padding(.bottom, 24)

            stateCard
                .padding(.horizontal, 24)

            Spacer()

            bottomActions
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
        }
        .task { await importViewModel.loadExisting() }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.zip]) { result in
            // Il pannello si chiude da solo alla scelta del file: da lì in poi si vede
            // la card col progresso. Il picker annullato non è un errore.
            if case .success(let url) = result {
                Task { await importViewModel.importFile(at: url) }
            }
        }
    }

    // MARK: Card centrale, per stato

    @ViewBuilder
    private var stateCard: some View {
        switch importViewModel.state {
        case .sources:
            VStack(spacing: 12) {
                sourceRow
                comingSoonRow
            }
        case .uploading:
            progressCard(labelKey: "import.state.uploading", progress: 0.1)
        case .running(_, let phase):
            progressCard(labelKey: phaseLabelKey(phase), progress: phaseProgress(phase))
        case .done(let report):
            completedCard(report)
        case .failed(let messageKey, let detail, _):
            failedCard(messageKey: messageKey, detail: detail)
        }
    }

    /// La riga TV Time del prototipo: tessera gialla, bordo acceso.
    private var sourceRow: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 14) {
                TVTimeBadge()
                VStack(alignment: .leading, spacing: 3) {
                    Text("onboarding.import.tvtime".localized)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                    Text("onboarding.import.tvtime.subtitle".localized)
                        .font(.system(size: 13))
                        .foregroundColor(.theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.theme.accentOrange)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(hex: "f5c518").opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 18)
                        .stroke(Color(hex: "f5c518").opacity(0.45), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    private var comingSoonRow: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.theme.textSecondary.opacity(0.6))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text("onboarding.import.other".localized)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.theme.textSecondary.opacity(0.7))
                Text("onboarding.import.other.subtitle".localized)
                    .font(.system(size: 13))
                    .foregroundColor(.theme.textSecondary.opacity(0.55))
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.03))
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1))
        )
    }

    /// La card col progresso ("Quasi fatto… 80%"). Il progresso è derivato dalla fase del
    /// server — le fasi sono discrete, la barra è una lettura onesta, non un cronometro.
    private func progressCard(labelKey: String, progress: Double) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                TVTimeBadge()
                Text(labelKey.localized)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.theme.accentOrange)
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Color.theme.accentOrange)
                .scaleEffect(x: 1, y: 1.6, anchor: .center)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
        .animation(.easeInOut(duration: 0.5), value: progress)
    }

    /// La card verde "Import completato" con i quattro numeri del prototipo.
    private func completedCard(_ report: ImportReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.green.opacity(0.9))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.black)
                    )
                Text("onboarding.import.completed".localized)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
            }

            let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
            LazyVGrid(columns: columns, spacing: 12) {
                statTile(report.serieImportate, key: "onboarding.import.stat.shows")
                statTile(report.episodiImportati, key: "onboarding.import.stat.episodes")
                statTile(report.filmImportati, key: "onboarding.import.stat.movies")
                statTile(report.statiSerieImportati + report.filmWatchlistImportati,
                         key: "onboarding.import.stat.watchlist")
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.green.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.green.opacity(0.35), lineWidth: 1))
        )
    }

    private func statTile(_ value: Int, key: String) -> some View {
        VStack(spacing: 4) {
            Text(value.formatted())
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            Text(key.localized)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }

    /// §7.4: l'errore non si abbellisce — chiave localizzata più la verità tecnica, piccola.
    private func failedCard(messageKey: String, detail: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundColor(.theme.textSecondary)
            Text(messageKey.localized)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .multilineTextAlignment(.center)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button("common.retry".localized) {
                Task { await importViewModel.retry() }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.theme.accentOrange)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    // MARK: Azioni in basso, per stato

    @ViewBuilder
    private var bottomActions: some View {
        switch importViewModel.state {
        case .sources, .failed:
            VStack(spacing: 18) {
                PrimaryButton(title: "onboarding.import.tvtime".localized) {
                    showPicker = true
                }
                Button {
                    viewModel.skipStep()
                } label: {
                    Text("onboarding.import.skip".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                }
            }
        case .uploading, .running:
            // Come nel prototipo: la CTA resta, spenta, finché il lavoro non è finito.
            PrimaryButton(title: "onboarding.import.tvtime".localized, action: {})
                .disabled(true)
                .opacity(0.5)
        case .done:
            PrimaryButton(title: "common.continue".localized) {
                viewModel.nextStep()
            }
        }
    }

    // MARK: Fasi del server → resa

    private func phaseLabelKey(_ phase: String) -> String {
        switch phase {
        case "uploaded":    return "import.phase.queued"
        case "parsing":     return "import.phase.parsing"
        case "resolving":   return "import.phase.resolving"
        case "writing":     return "import.phase.writing"
        case "recomputing": return "import.phase.finishing"
        default:            return "import.phase.queued"
        }
    }

    private func phaseProgress(_ phase: String) -> Double {
        switch phase {
        case "uploaded":    return 0.2
        case "parsing":     return 0.4
        case "resolving":   return 0.6
        case "writing":     return 0.8
        case "recomputing": return 0.95
        default:            return 0.2
        }
    }
}

/// La tessera gialla "tv:t" delle card di import.
private struct TVTimeBadge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(hex: "f5c518"))
            .frame(width: 48, height: 48)
            .overlay(
                Text("tv:t")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.black)
            )
    }
}

// MARK: - Tappa 4: Notifiche

struct OnboardingNotificationsStep: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            OnboardingHeroCircle(systemImage: "bell", badge: true)
                .padding(.bottom, 28)

            VStack(spacing: 14) {
                Text("onboarding.notifications.title".localized)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text("onboarding.notifications.subtitle".localized)
                    .font(.system(size: 16))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)
            }
            .padding(.bottom, 28)

            VStack(spacing: 12) {
                notificationRow("onboarding.notifications.row1")
                notificationRow("onboarding.notifications.row2")
                notificationRow("onboarding.notifications.row3")
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 18) {
                PrimaryButton(title: "onboarding.notifications.enable".localized,
                              isLoading: isRequesting) {
                    // Il popup nativo di iOS: qualunque sia la risposta si va avanti,
                    // la chip finale "Notifiche attive" appare solo se ha detto sì.
                    Task {
                        isRequesting = true
                        let granted = await NotificationService.shared.enableNotifications()
                        isRequesting = false
                        viewModel.notificationsGranted = granted
                        viewModel.nextStep()
                    }
                }

                Button {
                    viewModel.skipStep()
                } label: {
                    Text("onboarding.notifications.later".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private func notificationRow(_ key: String) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.theme.accentOrange.opacity(0.18))
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.theme.accentOrange)
                )
            Text(key.localized)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
    }
}

// MARK: - Tappa 5: Tutto pronto

struct OnboardingReadyStep: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var importViewModel: ImportViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Circle()
                .fill(Color.green.opacity(0.12))
                .frame(width: 120, height: 120)
                .overlay(Circle().stroke(Color.green.opacity(0.35), lineWidth: 1))
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundColor(.green)
                )
                .padding(.bottom, 28)

            VStack(spacing: 14) {
                Text("onboarding.ready.title".localized)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text("onboarding.ready.subtitle".localized)
                    .font(.system(size: 16))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)
            }
            .padding(.bottom, 22)

            chips
                .padding(.horizontal, 24)

            Spacer()

            PrimaryButton(title: "onboarding.ready.cta".localized,
                          isLoading: viewModel.isCheckingProStatus) {
                // Il paywall arriva solo per chi non è già PRO: la decisione sta nel ViewModel.
                Task { await viewModel.finish() }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    /// Le chip del prototipo: i numeri dell'import (solo se c'è stato) e "Notifiche attive"
    /// (solo se il permesso è stato concesso davvero).
    @ViewBuilder
    private var chips: some View {
        HStack(spacing: 10) {
            if case .done(let report) = importViewModel.state {
                chip(String(format: "onboarding.ready.chip.shows".localized,
                            report.serieImportate))
                chip(String(format: "onboarding.ready.chip.episodes".localized,
                            report.episodiImportati))
            }
            if viewModel.notificationsGranted {
                Text("onboarding.ready.chip.notifications".localized)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.theme.accentOrange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        Capsule()
                            .fill(Color.theme.accentOrange.opacity(0.1))
                            .overlay(Capsule().stroke(Color.theme.accentOrange.opacity(0.5),
                                                      lineWidth: 1))
                    )
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

// MARK: - Componenti condivisi

/// Il cerchio-hero delle tappe account e notifiche: fondo caldo appena tinto, icona arancione.
struct OnboardingHeroCircle: View {
    let systemImage: String
    var badge: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(Color.theme.accentOrange.opacity(0.08))
                .frame(width: 130, height: 130)
                .overlay(Circle().stroke(Color.theme.accentOrange.opacity(0.3), lineWidth: 1))
                .overlay(
                    Image(systemName: systemImage)
                        .font(.system(size: 46, weight: .regular))
                        .foregroundColor(.theme.accentOrange)
                )
            if badge {
                Circle()
                    .fill(Color.theme.accentOrange)
                    .frame(width: 12, height: 12)
                    .offset(x: -14, y: 14)
            }
        }
    }
}

/// La CTA arancione a pillola del prototipo, con spinner opzionale.
struct PrimaryButton: View {
    let title: String
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Color.theme.background))
                } else {
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(Color.theme.background)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.theme.accentOrange)
            .clipShape(Capsule())
            .shadow(color: Color.theme.accentOrange.opacity(0.3), radius: 10, x: 0, y: 5)
        }
        .disabled(isLoading)
    }
}
