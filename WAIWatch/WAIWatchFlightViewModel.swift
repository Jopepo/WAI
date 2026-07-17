import Foundation
import WatchConnectivity

struct WAIWatchFlight: Equatable {
    let legID: String
    let flightNumber: String
    let origin: String
    let destination: String
    let scheduledDeparture: Date?
}

@MainActor
final class WAIWatchFlightViewModel: NSObject, ObservableObject {
    @Published private(set) var flight: WAIWatchFlight?
    @Published private(set) var takeoffAt: Date?

    private let session: WCSession?
    private let defaults = UserDefaults.standard
    private let legIDKey = "wai.watch.activeLegID"
    private let takeoffKey = "wai.watch.takeoffAt"
    private let completedLegIDKey = "wai.watch.completedLegID"

    override init() {
        session = WCSession.isSupported() ? .default : nil
        super.init()
        if defaults.object(forKey: takeoffKey) != nil {
            takeoffAt = Date(
                timeIntervalSince1970: defaults.double(forKey: takeoffKey)
            )
        }
        session?.delegate = self
        session?.activate()
        if let context = session?.receivedApplicationContext {
            apply(context)
        }
    }

    func recordTakeoff(at date: Date = Date()) {
        guard let flight else { return }
        takeoffAt = date
        defaults.removeObject(forKey: completedLegIDKey)
        defaults.set(flight.legID, forKey: legIDKey)
        defaults.set(date.timeIntervalSince1970, forKey: takeoffKey)
        send([
            "action": "takeoff",
            "legID": flight.legID,
            "takeoffAt": date.timeIntervalSince1970
        ])
    }

    func recordLanding(at date: Date = Date()) {
        guard let flight, let takeoffAt, date > takeoffAt else { return }
        send([
            "action": "landing",
            "legID": flight.legID,
            "takeoffAt": takeoffAt.timeIntervalSince1970,
            "landingAt": date.timeIntervalSince1970
        ])
        self.takeoffAt = nil
        defaults.set(flight.legID, forKey: completedLegIDKey)
        defaults.removeObject(forKey: legIDKey)
        defaults.removeObject(forKey: takeoffKey)
    }

    private func apply(_ context: [String: Any]) {
        guard let legID = context["legID"] as? String,
              let flightNumber = context["flightNumber"] as? String,
              let origin = context["origin"] as? String,
              let destination = context["destination"] as? String else {
            flight = nil
            return
        }
        flight = WAIWatchFlight(
            legID: legID,
            flightNumber: flightNumber,
            origin: origin,
            destination: destination,
            scheduledDeparture: (context["scheduledDeparture"] as? TimeInterval)
                .map(Date.init(timeIntervalSince1970:))
        )
        let completedLegID = defaults.string(forKey: completedLegIDKey)
        if completedLegID == legID {
            takeoffAt = nil
        } else if let remoteTakeoff = context["takeoffAt"] as? TimeInterval {
            takeoffAt = Date(timeIntervalSince1970: remoteTakeoff)
        } else if defaults.string(forKey: legIDKey) != legID {
            takeoffAt = nil
        }
        if completedLegID != nil, completedLegID != legID {
            defaults.removeObject(forKey: completedLegIDKey)
        }
    }

    private func send(_ payload: [String: Any]) {
        guard let session else { return }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { [weak self] _ in
                self?.session?.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
    }
}

extension WAIWatchFlightViewModel: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let context = session.receivedApplicationContext
        Task { @MainActor [weak self] in self?.apply(context) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor [weak self] in self?.apply(applicationContext) }
    }
}
