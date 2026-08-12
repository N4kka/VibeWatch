import SwiftUI
import UIKit

/// Il contenitore unico delle modali dell'app.
///
/// Prima convivevano quattro estetiche diverse per la stessa domanda ("sei sicuro?"):
/// `ConfirmationPopup`, un foglio custom per la serie vista, gli `.alert` di sistema e i
/// `.confirmationDialog`. Chi apriva due modali di fila vedeva due app diverse. Qui c'è una sola
/// forma — indicatore, titolo grande, sottotitolo, X circolare, contenuto, CTA arancione a
/// capsula e un secondario testuale — e ogni modale ridisegnata la usa.
struct VWModalSheet<Content: View>: View {
    let title: String
    var subtitle: String?
    /// Presente solo nelle sottopagine: torna al passo precedente invece di chiudere.
    var onBack: (() -> Void)?
    var onClose: () -> Void

    var primaryTitle: String?
    var primaryEnabled: Bool = true
    var primaryIsDestructive: Bool = false
    var primaryAction: (() -> Void)?

    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            // L'indicatore è disegnato qui, non da `presentationDragIndicator`: serve dentro il
            // ritmo verticale del foglio, non appiccicato al bordo del sistema.
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 42, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 18)
                .vwMeasuredForDetent()

            header
                .vwMeasuredForDetent()

            // Solo il contenuto scorre: header e CTA restano ancorati, così la CTA non finisce
            // mai sotto il bordo del foglio e il titolo non viene tranciato in alto.
            ScrollView {
                content()
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vwMeasuredForDetent()
            }
            .scrollBounceBehavior(.basedOnSize)

            if primaryTitle != nil || secondaryTitle != nil {
                footer
                    .padding(.top, 20)
                    .vwMeasuredForDetent()
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.theme.background.ignoresSafeArea())
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if let onBack {
                circleButton(icon: "chevron.left", action: onBack)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 25, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundColor(.theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            circleButton(icon: "xmark", action: onClose)
                .padding(.top, 2)
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            if let primaryTitle, let primaryAction {
                Button(action: primaryAction) {
                    Text(primaryTitle)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(primaryEnabled ? .black : Color.theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            Capsule().fill(
                                primaryEnabled
                                ? (primaryIsDestructive ? Color.red : Color.theme.accentOrange)
                                : Color.white.opacity(0.08)
                            )
                        )
                }
                .disabled(!primaryEnabled)
            }

            if let secondaryTitle, let secondaryAction {
                Button(action: secondaryAction) {
                    Text(secondaryTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
            }
        }
    }

    private func circleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}

/// La conferma compatta: un titolo, una frase e due bottoni. Sostituisce `ConfirmationPopup`.
struct VWConfirmationSheet: View {
    let title: String
    var message: String?
    let confirmTitle: String
    var cancelTitle: String = "common.cancel".localized
    var isDestructive: Bool = false
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VWModalSheet(
            title: title,
            subtitle: message,
            onClose: onCancel,
            primaryTitle: confirmTitle,
            primaryIsDestructive: isDestructive,
            primaryAction: onConfirm,
            secondaryTitle: cancelTitle,
            secondaryAction: onCancel
        ) {
            EmptyView()
        }
    }
}

/// Riga di riepilogo con icona tonda colorata, usata dentro le modali (R6).
struct VWModalSummaryRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String
    var valueColor: Color = .theme.textPrimary

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(iconColor)
                .frame(width: 34, height: 34)
                .background(Circle().fill(iconColor.opacity(0.18)))

            Text(title)
                .font(.system(size: 15.5, weight: .medium))
                .foregroundColor(.theme.textPrimary)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 15.5, weight: .bold))
                .foregroundColor(valueColor)
        }
    }
}

/// Somma le altezze naturali dei pezzi di `VWModalSheet` (indicatore, header, contenuto, footer).
/// Il contenuto è misurato **dentro** lo `ScrollView`, dove non è compresso dal detent corrente:
/// altrimenti la misura inseguirebbe se stessa.
struct VWModalContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

extension View {
    fileprivate func vwMeasuredForDetent() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: VWModalContentHeightKey.self, value: proxy.size.height)
            }
        )
    }
}

@MainActor
private enum VWScreenMetrics {
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    /// Il detent non deve mai superare lo schermo: oltre questa soglia si usa `.large`.
    static var maxSheetHeight: CGFloat { (keyWindow?.screen.bounds.height ?? 844) * 0.9 }

    /// L'altezza del foglio comprende l'area sotto il contenuto (home indicator).
    static var bottomSafeArea: CGFloat { keyWindow?.safeAreaInsets.bottom ?? 0 }
}

private struct VWModalPresentationModifier: ViewModifier {
    /// Il padding inferiore del contenitore di `VWModalSheet`: non è dentro nessuno dei pezzi
    /// misurati, ma fa parte dell'altezza del foglio.
    private static let bottomPadding: CGFloat = 18

    let forcedDetents: Set<PresentationDetent>?

    @State private var measured: CGFloat = 0
    @State private var selection: PresentationDetent = .medium

    private static func sheetHeight(for measured: CGFloat) -> CGFloat {
        min(
            measured + bottomPadding + VWScreenMetrics.bottomSafeArea,
            VWScreenMetrics.maxSheetHeight
        )
    }

    private var detents: Set<PresentationDetent> {
        if let forcedDetents { return forcedDetents }
        guard measured > 0 else { return [.medium, .large] }
        return [.height(Self.sheetHeight(for: measured)), .large]
    }

    func body(content: Content) -> some View {
        Group {
            if let forcedDetents {
                content.presentationDetents(forcedDetents)
            } else {
                content
                    .onPreferenceChange(VWModalContentHeightKey.self) { total in
                        let rounded = total.rounded()
                        guard rounded > 0, abs(rounded - measured) > 1 else { return }
                        measured = rounded
                        selection = .height(Self.sheetHeight(for: rounded))
                    }
                    .presentationDetents(detents, selection: $selection)
            }
        }
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color.theme.background)
        .preferredColorScheme(.dark)
    }
}

extension View {
    /// La presentazione condivisa delle modali ridisegnate: sfondo scuro, niente indicatore di
    /// sistema (lo disegna `VWModalSheet`) e **altezza misurata sul contenuto**, così una modale
    /// alta non viene tagliata e una bassa non lascia una fascia vuota sotto la CTA.
    /// `detents` resta come scappatoia per i fogli che non passano da `VWModalSheet`.
    func vwModalPresentation(detents: Set<PresentationDetent>? = nil) -> some View {
        modifier(VWModalPresentationModifier(forcedDetents: detents))
    }
}
