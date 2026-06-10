import SwiftUI

@main
/*struct WAIApp: App {
    @StateObject private var subscriptionManager = SubscriptionManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(subscriptionManager)
                .task {
                    await subscriptionManager.refresh()
                }
        }
    }
}*/
// TEMP: Paywall bypass for early TestFlight testing.
// Restore RootView before monetized/public release.
struct WAIApp: App {
    @StateObject private var subscriptionManager = SubscriptionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}


struct RootView: View {
    @EnvironmentObject private var subscriptionManager: SubscriptionManager

    var body: some View {
        Group {
            if subscriptionManager.isLoading {
                ProgressView("Checking access…")
            } else if subscriptionManager.hasPremiumAccess {
                ContentView()
            } else {
                PaywallView()
            }
        }
    }
}
