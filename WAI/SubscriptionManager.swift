import Foundation
import StoreKit

@MainActor
final class SubscriptionManager: ObservableObject {
    static let premiumProductID = "wai.premium.monthly"

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedProductIDs: Set<String> = []
    @Published private(set) var isLoading = true
    @Published var purchaseErrorMessage: String?

    var premiumProduct: Product? {
        products.first { $0.id == Self.premiumProductID }
    }

    var hasPremiumAccess: Bool {
        purchasedProductIDs.contains(Self.premiumProductID)
    }

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = listenForTransactionUpdates()

        Task {
            await loadProducts()
            await updatePurchasedProducts()
            isLoading = false
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProducts() async {
        do {
            products = try await Product.products(for: [Self.premiumProductID])
            purchaseErrorMessage = nil
        } catch {
            purchaseErrorMessage = "Could not load subscription. Check App Store Connect product configuration."
            products = []
        }
    }

    func purchasePremium() async {
        guard let product = premiumProduct else {
            purchaseErrorMessage = "Subscription product not available yet."
            return
        }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await updatePurchasedProducts()
                await transaction.finish()
                purchaseErrorMessage = nil

            case .userCancelled:
                break

            case .pending:
                purchaseErrorMessage = "Purchase is pending approval."

            @unknown default:
                purchaseErrorMessage = "Unknown purchase result."
            }
        } catch {
            purchaseErrorMessage = "Purchase failed. Try again later."
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await updatePurchasedProducts()
            purchaseErrorMessage = nil
        } catch {
            purchaseErrorMessage = "Could not restore purchases."
        }
    }

    func updatePurchasedProducts() async {
        var activeProductIDs = Set<String>()

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)

                if transaction.revocationDate == nil {
                    activeProductIDs.insert(transaction.productID)
                }
            } catch {
                continue
            }
        }

        purchasedProductIDs = activeProductIDs
    }

    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }

                do {
                    let transaction = try await self.checkVerified(result)
                    await self.updatePurchasedProducts()
                    await transaction.finish()
                } catch {
                    continue
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw PurchaseVerificationError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
}

enum PurchaseVerificationError: Error {
    case failedVerification
}
