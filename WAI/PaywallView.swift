import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject private var subscriptionManager: SubscriptionManager

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("WAI")
                .font(.largeTitle)
                .bold()

            Text("Where am I?")
                .font(.title3)

            VStack(spacing: 12) {
                Text("Premium Access")
                    .font(.title2)
                    .bold()

                Text("Wakeup and pickup calculations without ads.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("1 month free, then 1€/month")
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 20))

            if subscriptionManager.isLoading {
                ProgressView("Loading subscription…")
            } else {
                Button {
                    Task {
                        await subscriptionManager.purchaseMonthlySubscription()
                    }
                } label: {
                    Text(primaryButtonTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(subscriptionManager.products.first == nil)

                Button("Restore Purchases") {
                    Task {
                        await subscriptionManager.restorePurchases()
                    }
                }
                .buttonStyle(.bordered)
            }

            if let message = subscriptionManager.purchaseErrorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding()
    }

    private var primaryButtonTitle: String {
        if let product = subscriptionManager.products.first {
            return "Start Free Trial — then \(product.displayPrice)/month"
        }

        return "Subscription unavailable"
    }
}

#Preview {
    PaywallView()
        .environmentObject(SubscriptionManager())
}
