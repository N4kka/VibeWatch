import SwiftUI

/// Riga di chip filtro sopra l'input, con pill "Filtro applicato: X" quando ce n'è una attiva.
struct AIFilterChipsRow: View {
    let availableFilters: [AIChatFilter]
    let activeFilters: [AIChatFilter]
    let onToggle: (AIChatFilter) -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let active = activeFilters.first {
                Text(String(format: "ai.filter.applied".localized, appliedNames))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.05))
                    .overlay(
                        Capsule().stroke(Color.theme.accentOrange.opacity(0.7), lineWidth: 1.2)
                    )
                    .clipShape(Capsule())
                    .id(active)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(availableFilters, id: \.self) { filter in
                        FilterChip(
                            title: filter.chipLabel,
                            isSelected: activeFilters.contains(filter)
                        ) {
                            onToggle(filter)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var appliedNames: String {
        activeFilters.map { $0.appliedName }.joined(separator: ", ")
    }
}

/// Barra di input della chat: campo arrotondato + bottone invio circolare arancione.
struct AIChatInputBar: View {
    @Binding var prompt: String
    let isDisabled: Bool
    let onSend: () -> Void
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 12) {
            TextField("ai.placeholder2".localized, text: $prompt)
                .focused(focus)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .foregroundStyle(Color.theme.textPrimary)
                .submitLabel(.send)
                .disabled(isDisabled)
                .onSubmit(onSend)

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 46, height: 46)
                    .background(
                        prompt.isEmpty || isDisabled
                            ? Color.theme.textSecondary.opacity(0.4)
                            : Color.theme.accentOrange
                    )
                    .clipShape(Circle())
            }
            .disabled(prompt.isEmpty || isDisabled)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
