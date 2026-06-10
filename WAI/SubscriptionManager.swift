import Foundation
import StoreKit

@MainActor
final class SubscriptionManager: ObservableObject {
    @Published var hasPremiumAccess = false
    @Published var isLoading = true
    @Published var products: [Product] = []
    @Published var purchaseErrorMessage: String?

    private let productIDs = ["wai.premium.monthly"]

    func refresh() async {
        isLoading = true
        purchaseErrorMessage = nil

        await loadProducts()
        await updateEntitlements()

        isLoading = false
    }

    func loadProducts() async {
        do {
            print("🟡 Loading StoreKit products:", productIDs)

            products = try await Product.products(for: productIDs)

            print("🟢 Products loaded:", products.map { $0.id })

            if products.isEmpty {
                purchaseErrorMessage = "No products returned by StoreKit. Check Product ID, subscription status, app version association, and propagation delay."
            } else {
                purchaseErrorMessage = nil
            }
        } catch {
            print("🔴 StoreKit product loading failed:", error.localizedDescription)
            purchaseErrorMessage = "StoreKit error: \(error.localizedDescription)"
            products = []
        }
    }

    func purchaseMonthlySubscription() async {
        guard let product = products.first else {
            purchaseErrorMessage = "Subscription is not available yet."
            return
        }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await updateEntitlements()

                case .unverified:
                    purchaseErrorMessage = "Purchase could not be verified."
                }

            case .userCancelled:
                break

            case .pending:
                purchaseErrorMessage = "Purchase is pending approval."

            @unknown default:
                purchaseErrorMessage = "Unknown purchase result."
            }
        } catch {
            purchaseErrorMessage = "Purchase failed."
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await updateEntitlements()
        } catch {
            purchaseErrorMessage = "Could not restore purchases."
        }
    }

    func updateEntitlements() async {
        var activeAccess = false

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                continue
            }

            if productIDs.contains(transaction.productID),
               transaction.revocationDate == nil,
               transaction.expirationDate ?? .distantFuture > Date() {
                activeAccess = true
            }
        }

        hasPremiumAccess = activeAccess
    }
}
