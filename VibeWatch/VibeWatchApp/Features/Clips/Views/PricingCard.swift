import SwiftUI

struct PricingCard: View {
    let planName: String
    let priceText: String
    var descriptionText: String?
    var trialText: String?
    var discountText: String?
    var isBestValue: Bool = false
    var isSelected: Bool
    var accentColor: Color = Color.orange
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 14) {
                header

                Text(priceText)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)

                if let descriptionText {
                    Text(descriptionText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }

                if let trialText {
                    Text(trialText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(accentColor)
                }

                if let discountText {
                    Text(discountText.uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(accentColor)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(accentColor.opacity(0.18))
                        .cornerRadius(10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(isSelected ? 0.18 : 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(isSelected ? accentColor : Color.white.opacity(0.15), lineWidth: isSelected ? 2 : 1)
                    )
                    .shadow(color: accentColor.opacity(isSelected ? 0.2 : 0), radius: 18, x: 0, y: 10)
            )
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 10) {
                Text(planName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                if isBestValue {
                    Text("paywall.bestValue".localized)
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(accentColor)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(accentColor.opacity(0.16))
                        .cornerRadius(8)
                }
            }

            Spacer()

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(isSelected ? accentColor : .white.opacity(0.65))
        }
    }
}

struct PricingCard_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                PricingCard(
                    planName: "Monthly",
                    priceText: "$4.99",
                    descriptionText: "Billed monthly",
                    trialText: "7 days free",
                    isSelected: true
                ) {}

                PricingCard(
                    planName: "Annual",
                    priceText: "$39.99",
                    descriptionText: "Billed annually",
                    trialText: "7 days free",
                    discountText: "Save 17%",
                    isBestValue: true,
                    isSelected: false
                ) {}
            }
            .padding()
        }
    }
}
