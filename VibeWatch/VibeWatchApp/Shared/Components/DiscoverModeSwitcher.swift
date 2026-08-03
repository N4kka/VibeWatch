import SwiftUI

/// Redesign 2.0 — Scopri e Clip sono la stessa area, con uno switcher al posto di due tab.
///
/// La decisione sta nel prototipo Claude Design ("Decisioni chiave"): fondere le due superfici
/// libera uno slot nella barra, che resta a 4 tab con Social come quinta area. Lo switcher è
/// l'unico posto da cui si cambia modalità: un segmented control locale, non un tab nascosto.
enum DiscoverMode: String, Hashable {
    case discover
    case clips
}

struct DiscoverModeSwitcher: View {
    @Binding var mode: DiscoverMode

    var body: some View {
        Picker(selection: $mode) {
            Text("tab.discovery".localized)
                .tag(DiscoverMode.discover)

            Text("tab.clips".localized)
                .tag(DiscoverMode.clips)
        } label: {
            EmptyView()
        }
        // Come la TabView su iOS 26, il Picker segmentato riceve dal sistema il Liquid Glass,
        // inclusi selezione, animazione e feedback. Il tint colora solo il contenuto attivo,
        // senza reintrodurre fill o glassEffect custom.
        .pickerStyle(.segmented)
        .tint(.theme.accentOrange)
        .labelsHidden()
        .frame(width: 190)
    }
}
