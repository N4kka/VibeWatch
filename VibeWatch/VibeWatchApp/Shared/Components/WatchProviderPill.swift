import SwiftUI

/// La pillola "dove lo guardo" sulla card del Tracking — l'erede di quella del vecchio
/// tracking dentro ListsView, con in più l'etichetta dello scaffale.
///
/// La logica è quella chiesta dal prodotto (2026-08-01):
/// 1. c'è streaming → "Guarda su {piattaforma}", la prima valida (Flatrate);
/// 2. niente streaming → prima il noleggio, poi l'acquisto ("Noleggia su" / "Acquista su") —
///    l'etichetta dice lo scaffale perché noleggio e acquisto costano, e una pillola che non lo
///    dice invita a un tap che delude;
/// 3. niente su nessuno scaffale → "Avvisami", identica alla ListsView (stesse chiavi, stesso
///    alert).
///
/// I provider arrivano da `LiveWatchProvidersRepository` (cache locale prima, rete se serve):
/// la card si disegna subito con lo scheletro e la pillola arriva quando arriva — il budget di
/// §13.6 riguarda il primo fotogramma della schermata, non questo aggiornamento successivo.
struct WatchProviderPill: View {
    let mediaId: Int
    let mediaType: MediaType
    let title: String

    private enum Phase: Equatable {
        case checking
        case found(Provider, ProviderSelection.Tier, link: String?)
        case none
    }

    @State private var phase: Phase = .checking
    @State private var showNotifyAlert = false

    var body: some View {
        Group {
            switch phase {
            case .checking:
                skeleton
            case .found(let provider, let tier, let link):
                providerChip(provider, tier: tier, link: link)
            case .none:
                notifyChip
            }
        }
        .task(id: "\(mediaType.rawValue)-\(mediaId)") { await load() }
        .alert("lists.notifyMeTitle".localized, isPresented: $showNotifyAlert) {
            Button("common.ok".localized, role: .cancel) {}
        } message: {
            Text(String(format: "lists.notifyMeMessage".localized, title))
        }
    }

    private func labelKey(for tier: ProviderSelection.Tier) -> String {
        switch tier {
        case .flatrate: return "tracking.watchOn"
        case .rent: return "tracking.rentOn"
        case .buy: return "tracking.buyOn"
        }
    }

    private func providerChip(_ provider: Provider, tier: ProviderSelection.Tier, link: String?) -> some View {
        Button {
            PlatformDeepLinkHelper.openPlatform(
                provider: provider, justWatchLink: link, title: title)
        } label: {
            HStack(spacing: 6) {
                CachedAsyncImage(url: provider.logoURL)
                    .frame(width: 18, height: 18)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text(String(format: labelKey(for: tier).localized, provider.providerName))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(.theme.textPrimary)
            .padding(.leading, 7)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.07))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var notifyChip: some View {
        Button {
            showNotifyAlert = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bell")
                    .font(.system(size: 11, weight: .semibold))
                Text("lists.notifyMe".localized)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(.theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.07))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// Scheletro discreto mentre la disponibilità si risolve: né una pillola vuota né un salto
    /// di layout quando arriva quella vera.
    private var skeleton: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(0.10))
                .frame(width: 18, height: 18)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.10))
                .frame(width: 84, height: 10)
        }
        .padding(.leading, 7)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05))
        .clipShape(Capsule())
    }

    private func load() async {
        phase = .checking
        let region = LocalizationManager.shared.currentCountry.id
        var best: Phase = .none
        for await providers in LiveWatchProvidersRepository.shared.observeProviders(
            mediaId: mediaId, mediaType: mediaType, region: region
        ) {
            guard let providers else { continue }
            let result = ProviderSelection.selectTopProviderWithTier(from: providers)
            if let top = result.top, let tier = result.tier {
                best = .found(top, tier, link: result.link)
            }
        }
        // Lo stream è finito: o abbiamo uno scaffale, o la risposta onesta è "avvisami".
        // Lo scheletro non resta mai a schermo a fingere che stia ancora cercando.
        phase = best
    }
}
