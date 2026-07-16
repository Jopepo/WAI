import Foundation

enum WAI3FlightDurationInput {
    static func sanitizedComponent(_ value: String) -> String {
        String(
            value.filter { $0.isASCII && $0.isNumber }.prefix(2)
        )
    }

    static func totalMinutes(
        hours: String,
        minutes: String
    ) -> Int? {
        guard let hours = Int(hours),
              let minutes = Int(minutes),
              (0...24).contains(hours),
              (0...59).contains(minutes),
              hours < 24 || minutes == 0 else {
            return nil
        }
        let total = hours * 60 + minutes
        return (1...1_440).contains(total) ? total : nil
    }

    static func components(
        totalMinutes: Int
    ) -> (hours: String, minutes: String) {
        let bounded = min(max(totalMinutes, 0), 1_440)
        let hours = bounded / 60
        let minutes = bounded == 1_440 ? 0 : bounded % 60
        return (
            hours: String(hours),
            minutes: String(format: "%02d", minutes)
        )
    }
}
