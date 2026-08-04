import SwiftUI
import UIKit

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
        DiscoverModeSegmentedControl(mode: $mode)
            .frame(width: 190)
    }
}

/// `.tint` non viene applicato al titolo selezionato di un Picker segmentato. Configuriamo
/// quindi l'istanza UIKit usata da questo switcher, senza alterare l'appearance globale.
enum DiscoverModeSwitcherStyle {
    static func apply(to control: UISegmentedControl) {
        control.tintColor = UIColor(Color.theme.accentOrange)
        control.setTitleTextAttributes(
            [.foregroundColor: UIColor(Color.theme.textSecondary)],
            for: .normal
        )
        control.setTitleTextAttributes(
            [.foregroundColor: UIColor(Color.theme.accentOrange)],
            for: .selected
        )
    }
}

private struct DiscoverModeSegmentedControl: UIViewRepresentable {
    private static let modes: [DiscoverMode] = [.discover, .clips]

    @Binding var mode: DiscoverMode

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: $mode)
    }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: localizedTitles)
        DiscoverModeSwitcherStyle.apply(to: control)
        control.selectedSegmentIndex = selectedIndex
        control.addTarget(
            context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:)),
            for: .valueChanged
        )
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.mode = $mode

        for (index, title) in localizedTitles.enumerated()
        where control.titleForSegment(at: index) != title {
            control.setTitle(title, forSegmentAt: index)
        }

        if control.selectedSegmentIndex != selectedIndex {
            control.selectedSegmentIndex = selectedIndex
        }
    }

    private var localizedTitles: [String] {
        ["tab.discovery".localized, "tab.clips".localized]
    }

    private var selectedIndex: Int {
        Self.modes.firstIndex(of: mode) ?? 0
    }

    final class Coordinator: NSObject {
        var mode: Binding<DiscoverMode>

        init(mode: Binding<DiscoverMode>) {
            self.mode = mode
        }

        @objc func selectionChanged(_ sender: UISegmentedControl) {
            guard Self.isValid(index: sender.selectedSegmentIndex) else { return }
            mode.wrappedValue = DiscoverModeSegmentedControl.modes[sender.selectedSegmentIndex]
        }

        private static func isValid(index: Int) -> Bool {
            DiscoverModeSegmentedControl.modes.indices.contains(index)
        }
    }
}
