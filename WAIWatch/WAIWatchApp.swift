import SwiftUI

@main
struct WAIWatchApp: App {
    @StateObject private var model = WAIWatchFlightViewModel()

    var body: some Scene {
        WindowGroup {
            WAIWatchFlightView(model: model)
        }
    }
}

private struct WAIWatchFlightView: View {
    @ObservedObject var model: WAIWatchFlightViewModel

    var body: some View {
        Group {
            if let flight = model.flight {
                VStack(spacing: 8) {
                    Text(flight.flightNumber)
                        .font(.headline)
                    Text("\(flight.origin) → \(flight.destination)")
                        .font(.title3)
                        .fontWeight(.semibold)

                    if let takeoff = model.takeoffAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(duration(from: takeoff, to: context.date))
                                .font(.title2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Button(role: .destructive) {
                            model.recordLanding()
                        } label: {
                            Label("Land", systemImage: "airplane.arrival")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        if let departure = flight.scheduledDeparture {
                            Text(departure, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            model.recordTakeoff()
                        } label: {
                            Label("Take off", systemImage: "airplane.departure")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No flight",
                    systemImage: "airplane",
                    description: Text("Open WAI on iPhone to sync the roster.")
                )
            }
        }
        .padding(.horizontal, 6)
    }

    private func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3_600,
                      (seconds % 3_600) / 60, seconds % 60)
    }
}
