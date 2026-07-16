import Testing
@testable import WAI

struct WAI3CrewPresentationTests {
    private let captain = RosterCrewMember(
        employeeIdentifier: "10000.1",
        roleCode: "CPT",
        name: "Test Captain",
        isDeadhead: false
    )
    private let cabinCrew = RosterCrewMember(
        employeeIdentifier: "12345.6",
        roleCode: "CAB",
        name: "Test Crew Member",
        isDeadhead: false
    )

    @Test func identicalCrewIsPresentedOnceRegardlessOfOrder() {
        let presentation = WAI3CrewPresentation.resolve(
            crews: [
                [captain, cabinCrew],
                [cabinCrew, captain]
            ]
        )

        #expect(presentation == .shared([captain, cabinCrew]))
    }

    @Test func deadheadDifferenceIsPresentedPerLeg() {
        let deadheadCaptain = RosterCrewMember(
            employeeIdentifier: captain.employeeIdentifier,
            roleCode: captain.roleCode,
            name: captain.name,
            isDeadhead: true
        )

        #expect(
            WAI3CrewPresentation.resolve(
                crews: [[captain], [deadheadCaptain]]
            ) == .perLeg
        )
    }

    @Test func missingCrewOnOneLegIsNotAssumedToBeShared() {
        #expect(
            WAI3CrewPresentation.resolve(crews: [[captain], []]) == .perLeg
        )
    }

    @Test func emptyCrewIsNotPresented() {
        #expect(
            WAI3CrewPresentation.resolve(crews: [[], []]) == .unavailable
        )
    }
}
