import Foundation

enum WAI3CrewPresentation: Equatable, Sendable {
    case unavailable
    case shared([RosterCrewMember])
    case perLeg

    static func resolve(
        crews: [[RosterCrewMember]]
    ) -> WAI3CrewPresentation {
        guard crews.contains(where: { !$0.isEmpty }) else {
            return .unavailable
        }
        guard let first = crews.first else {
            return .unavailable
        }

        let firstSignature = signature(for: first)
        guard crews.dropFirst().allSatisfy({
            signature(for: $0) == firstSignature
        }) else {
            return .perLeg
        }
        return .shared(first)
    }

    private static func signature(
        for crew: [RosterCrewMember]
    ) -> [RosterCrewMember] {
        crew.sorted { lhs, rhs in
            lhs.id == rhs.id ? lhs.name < rhs.name : lhs.id < rhs.id
        }
    }
}
