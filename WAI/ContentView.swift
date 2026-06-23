import SwiftUI
import UIKit

struct ContentView: View {
    let stations = DataService.loadStations()
    let defaultAlternativeTag = "__DEFAULT__"
    let hours = Array(0...23)
    let minutes = Array(stride(from: 0, through: 55, by: 5))

    @State private var selectedStation = "WhereAmI?"
    @State private var selectedHour = 6
    @State private var selectedMinute = 0
    @State private var showingTimePicker = false
    @State private var selectedAlternative = "__DEFAULT__"
    @State private var showingFeedbackFallback = false

    var formattedTime: String {
        String(format: "%02d:%02d UTC", selectedHour, selectedMinute)
    }

    var selectedStationObject: Station? {
        stations.first { $0.iata == selectedStation }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Spacer().frame(height: 40)

                    Text("WAI")
                        .font(.largeTitle)
                        .bold()

                    Text("Where am I?")
                        .font(.title3)

                    Text("")
                        .font(.system(size: 50))

                    Text("Wakeup/Pickup Calculator")
                        .foregroundStyle(.secondary)

                    Picker("Destination", selection: $selectedStation) {
                        Text("WhereAmI?").tag("WhereAmI?")
                        ForEach(stations) { station in
                            Text("\(station.iata) - \(station.city)").tag(station.iata)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedStation) {
                        selectedAlternative = defaultAlternativeTag
                    }

                    if selectedStation != "WhereAmI?" {
                        timeInputView

                        if let station = selectedStationObject {
                            resultsView(for: station)
                        }
                    }

                    Spacer(minLength: 40)

                    bottomInfoSection
                }
                .padding()
            }
        }
    }

    var timeInputView: some View {
        VStack(spacing: 12) {
            Text("Flight Departure (UTC)")
                .font(.headline)

            Button {
                showingTimePicker.toggle()
            } label: {
                Text(formattedTime)
                    .font(.title2)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if showingTimePicker {
                VStack {
                    HStack(spacing: 0) {
                        Picker("Hour", selection: $selectedHour) {
                            ForEach(hours, id: \.self) { hour in
                                Text(String(format: "%02d", hour)).tag(hour)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 80)

                        Text(":")
                            .font(.title2)
                            .bold()

                        Picker("Minute", selection: $selectedMinute) {
                            ForEach(minutes, id: \.self) { minute in
                                Text(String(format: "%02d", minute)).tag(minute)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 80)
                    }
                    .frame(height: 120)

                    Button("Confirm") {
                        showingTimePicker = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal)
    }

    var bottomInfoSection: some View {
        VStack(spacing: 12) {
            Text("Transport Times: REV69 · 23 Jun 2026")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.gray.opacity(0.12))
                .clipShape(Capsule())

            feedbackButton
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    var feedbackButton: some View {
        Button {
            if UIApplication.shared.canOpenURL(feedbackMailtoURL) {
                UIApplication.shared.open(feedbackMailtoURL)
            } else {
                UIPasteboard.general.string = "joao.p.possidonio@gmail.com"
                showingFeedbackFallback = true
            }
        } label: {
            Label("Send feedback / report bug", systemImage: "envelope")
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.gray.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .alert("Email unavailable", isPresented: $showingFeedbackFallback) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("No email app is configured on this device. The feedback email address was copied to the clipboard.")
        }
    }

    func resultsView(for station: Station) -> some View {
        VStack(spacing: 16) {
            flightConversionCard(for: station)

            if !station.alternatives.isEmpty {
                VStack(spacing: 12) {
                    Text("Transport option")
                        .font(.headline)

                    Picker("Transport option", selection: $selectedAlternative) {
                        Text("Default").tag(defaultAlternativeTag)

                        ForEach(station.alternatives) { alternative in
                            Text(alternative.label).tag(alternative.label)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            if let result = calculateResult(for: station) {
                resultCard(result)
            } else {
                errorCard
            }
        }
        .padding(.horizontal)
    }

    func flightConversionCard(for station: Station) -> some View {
        VStack(spacing: 6) {
            Text("Flight")
                .font(.headline)

            Text("\(formattedTime) → \(localDepartureLabel(for: station))")
                .font(.title3)
                .bold()
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.gray.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    func resultCard(_ result: CalculationResult) -> some View {
        VStack(spacing: 14) {
            Text("Transport time used: \(result.transportTime)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 6) {
                Text("Wake-up")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(result.wakeup)
                    .font(.largeTitle)
                    .bold()
                    .minimumScaleFactor(0.5)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.yellow.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 6) {
                Text("Pick-up")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(result.pickup)
                    .font(.largeTitle)
                    .bold()
                    .minimumScaleFactor(0.5)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.red.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    var errorCard: some View {
        VStack(spacing: 10) {
            Text("⚠️")
                .font(.largeTitle)

            Text("No valid transport rule found")
                .font(.headline)

            Text("Check flight time or station configuration.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    func calculateResult(for station: Station) -> CalculationResult? {
        TimeCalculator.calculate(
            selectedHour: selectedHour,
            selectedMinute: selectedMinute,
            station: station,
            selectedAlternative: selectedAlternative,
            defaultAlternativeTag: defaultAlternativeTag
        )
    }

    func localDepartureLabel(for station: Station) -> String {
        TimeCalculator.localDepartureLabel(
            selectedHour: selectedHour,
            selectedMinute: selectedMinute,
            station: station
        )
    }

    var feedbackMailtoURL: URL {
        let subject = "WAI Feedback"
        let station = selectedStation == "WhereAmI?" ? "No station selected" : selectedStation
        let body = """
        Hi João,

        I want to send feedback about WAI.

        Station: \(station)
        Departure time: \(formattedTime)
        App version: \(appVersionLabel)

        Feedback / bug:

        """

        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
        let urlString = "mailto:joao.p.possidonio@gmail.com?subject=\(encodedSubject)&body=\(encodedBody)"

        return URL(string: urlString) ?? URL(string: "mailto:joao.p.possidonio@gmail.com")!
    }

    var appVersionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        return "\(version) (\(build))"
    }
}

#Preview {
    ContentView()
}
