import Foundation
import Network

final class EntitlementManager: ObservableObject {

    @Published var isPremium = false
    @Published var isOnline = false

    private let monitor = NWPathMonitor()

    init() {
        startMonitoring()
    }

    func startMonitoring() {

        let queue = DispatchQueue(label: "InternetMonitor")

        monitor.pathUpdateHandler = { path in

            DispatchQueue.main.async {

                if path.status == .satisfied {
                    self.isOnline = true
                } else {
                    self.isOnline = false
                }
            }
        }

        monitor.start(queue: queue)
    }

    var canUseApp: Bool {
        return isPremium || isOnline
    }
}
