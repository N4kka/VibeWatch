import SwiftUI

/// Le regole della password, sotto il campo, sempre visibili mentre si scrive.
///
/// Prima comparivano solo in rosso e solo dopo un errore: l'utente scopriva la regola sbagliando.
/// Qui la checklist è viva — i segmenti misurano la forza, i chip si accendono uno a uno.
struct PasswordRequirementsChecklist: View {
    let password: String

    private var checks: [(key: String, satisfied: Bool)] {
        ValidationHelper.passwordChecks(password)
    }

    private var satisfiedCount: Int {
        checks.filter(\.satisfied).count
    }

    /// 4 segmenti su 5 requisiti: il primo si accende appena si soddisfa un requisito.
    private var filledSegments: Int {
        guard satisfiedCount > 0 else { return 0 }
        return min(4, Int((Double(satisfiedCount) / Double(checks.count) * 4).rounded(.up)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index < filledSegments
                              ? Color.theme.accentOrange
                              : Color.white.opacity(0.12))
                        .frame(height: 2)
                }
            }

            // Le regole stanno su più righe: con cinque chip una riga sola non basta.
            FlowLayout(spacing: 8) {
                ForEach(checks, id: \.key) { check in
                    chip(for: check)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: satisfiedCount)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(checks.map { $0.key.localized }.joined(separator: ", "))
        .accessibilityValue("\(satisfiedCount)/\(checks.count)")
    }

    private func chip(for check: (key: String, satisfied: Bool)) -> some View {
        HStack(spacing: 5) {
            Text("·")
            Text(check.key.localized)
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundColor(check.satisfied ? .theme.accentOrange : .theme.textSecondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(check.satisfied
                           ? Color.theme.accentOrange.opacity(0.14)
                           : Color.white.opacity(0.08))
        )
    }
}
