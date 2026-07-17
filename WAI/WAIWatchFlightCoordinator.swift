import Foundation
import WatchConnectivity

enum WAIWatchFlightAction: Equatable, Sendable {
    case takeoff(legID: String, at: Date)
    case landing(legID: String, takeoffAt: Date, landingAt: Date)
}

@MainActor
final class WAIWatchFlightCoordinator: NSObject, ObservableObject {
    var actionHandler: ((WAIWatchFlightAction) -> Void)?

    private let session: WCSession?

    override init() {
        session = WCSession.isSupported() ? .default : nil
        super.init()
    }

    func start() {
        session?.delegate = self
        session?.activate()
    }

    func publish(
        duties: [RosterDuty],
        actualFlights: [String: RosterLegActualFlightRecord],
        referenceDate: Date = Date()
    ) {
        guard let session else { return }
        let legs = duties.flatMap { duty in
            duty.legs.map { (duty, $0) }
        }
        let selected = legs.first { _, leg in
            actualFlights[leg.id]?.landingAt == nil
            && actualFlights[leg.id] != nil
        } ?? legs
            .filter { _, leg in
                guard actualFlights[leg.id]?.landingAt == nil else {
                    return false
                }
                guard let arrival = leg.arrival.instant else { return false }
                return arrival > referenceDate.addingTimeInterval(-2 * 60 * 60)
            }
            .sorted {
                ($0.1.departure.instant ?? .distantFuture)
                    < ($1.1.departure.instant ?? .distantFuture)
            }
            .first

        guard let (_, leg) = selected else {
            try? session.updateApplicationContext(["version": 1])
            return
        }
        var context: [String: Any] = [
            "version": 1,
            "legID": leg.id,
            "flightNumber": leg.flightNumber,
            "origin": leg.originIATA,
            "destination": leg.destinationIATA
        ]
        if let departure = leg.departure.instant {
            context["scheduledDeparture"] = departure.timeIntervalSince1970
        }
        if let actual = actualFlights[leg.id], actual.landingAt == nil {
            let takeoff = actual.takeoffAt
            context["takeoffAt"] = takeoff.timeIntervalSince1970
        }
        try? session.updateApplicationContext(context)
    }

    private func receive(_ payload: [String: Any]) {
        guard let action = payload["action"] as? String,
              let legID = payload["legID"] as? String,
              !legID.isEmpty else {
            return
        }
        switch action {
        case "takeoff":
            guard let raw = payload["takeoffAt"] as? TimeInterval else {
                return
            }
            actionHandler?(.takeoff(
                legID: legID,
                at: Date(timeIntervalSince1970: raw)
            ))
        case "landing":
            guard let takeoffRaw = payload["takeoffAt"] as? TimeInterval,
                  let landingRaw = payload["landingAt"] as? TimeInterval else {
                return
            }
            actionHandler?(.landing(
                legID: legID,
                takeoffAt: Date(timeIntervalSince1970: takeoffRaw),
                landingAt: Date(timeIntervalSince1970: landingRaw)
            ))
        default:
            return
        }
    }
}

extension WAIWatchFlightCoordinator: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        Task { @MainActor [weak self] in self?.receive(message) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        Task { @MainActor [weak self] in self?.receive(userInfo) }
    }
}
