import Testing
@testable import WAI

struct WAI3FlightDurationInputTests {
    @Test func parsesDirectHourAndMinuteInput() {
        #expect(
            WAI3FlightDurationInput.totalMinutes(
                hours: "3",
                minutes: "25"
            ) == 205
        )
        #expect(
            WAI3FlightDurationInput.totalMinutes(
                hours: "0",
                minutes: "45"
            ) == 45
        )
    }

    @Test func rejectsEmptyZeroAndOutOfRangeDurations() {
        #expect(
            WAI3FlightDurationInput.totalMinutes(
                hours: "",
                minutes: "30"
            ) == nil
        )
        #expect(
            WAI3FlightDurationInput.totalMinutes(
                hours: "0",
                minutes: "00"
            ) == nil
        )
        #expect(
            WAI3FlightDurationInput.totalMinutes(
                hours: "2",
                minutes: "60"
            ) == nil
        )
        #expect(
            WAI3FlightDurationInput.totalMinutes(
                hours: "24",
                minutes: "01"
            ) == nil
        )
    }

    @Test func acceptsMaximumDuration() {
        #expect(
            WAI3FlightDurationInput.totalMinutes(
                hours: "24",
                minutes: "00"
            ) == 1_440
        )
        #expect(
            WAI3FlightDurationInput.totalMinutes(
                hours: 3,
                minutes: 25
            ) == 205
        )
    }

    @Test func sanitizesAndFormatsComponents() {
        #expect(
            WAI3FlightDurationInput.sanitizedComponent("a123") == "12"
        )
        let components = WAI3FlightDurationInput.components(
            totalMinutes: 185
        )
        #expect(components.hours == "3")
        #expect(components.minutes == "05")
    }
}
