import SwiftUI

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

    var formattedTime: String {
        String(format: "%02d:%02d UTC", selectedHour, selectedMinute)
    }

    var selectedStationObject: Station? {
        stations.first { $0.iata == selectedStation }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {

                Spacer().frame(height: 40)

                Text("WAI").font(.largeTitle).bold()
                Text("Where am I?").font(.title3)
                Text("🥱").font(.system(size: 50))
                Text("Wakeup/Pickup Calculator").foregroundStyle(.secondary)

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

                Spacer()
            }
            .padding()
        }
    }

    var timeInputView: some View {
        VStack(spacing: 12) {
            Text("Flight Departure (UTC)").font(.headline)

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

                        Text(":").font(.title2).bold()

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

    func resultsView(for station: Station) -> some View {
        VStack(spacing: 16) {

            flightConversionCard(for: station)

            if !station.alternatives.isEmpty {
                VStack(spacing: 12) {
                    Text("Hotel / Scenario").font(.headline)

                    Picker("Alternative", selection: $selectedAlternative) {
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
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.gray.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    func resultCard(_ result: CalculationResult) -> some View {
        VStack(spacing: 10) {
            Text("Pickup")
                .font(.headline)

            Text(result.pickup)
                .font(.largeTitle)
                .bold()

            Text("Wake-up")
                .font(.headline)

            Text(result.wakeup)
                .font(.largeTitle)
                .bold()
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    var errorCard: some View {
        VStack(spacing: 10) {
            Text("⚠️").font(.largeTitle)
            Text("No valid transport rule found").font(.headline)
            Text("Check flight time or station configuration.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    func calculateResult(for station: Station) -> CalculationResult? {
        let localDeparture = localDepartureMinutes(for: station)

        if selectedAlternative != defaultAlternativeTag,
           let alternative = station.alternatives.first(where: {
               $0.label == selectedAlternative
           }) {
            return exactResult(
                departureMinutes: localDeparture,
                transportMinutes: alternative.transportMinutes,
                station: station
            )
        }

        switch station.defaultRule.type {

        case "fixed":
            guard let transport = station.defaultRule.transportMinutes else {
                return nil
            }

            return exactResult(
                departureMinutes: localDeparture,
                transportMinutes: transport,
                station: station
            )

        case "timeDependent":
            guard let rules = station.defaultRule.rules else {
                return nil
            }

            let isWeekend = isWeekendToday()

            for rule in rules {
                if rule.weekendsAndHolidaysOnly == true && isWeekend {
                    return exactResult(
                        departureMinutes: localDeparture,
                        transportMinutes: rule.transportMinutes,
                        station: station
                    )
                }

                if rule.weekdaysOnly == true && isWeekend {
                    continue
                }

                guard let fromLocal = rule.fromLocal,
                      let toLocal = rule.toLocal else {
                    continue
                }

                let from = parse(time: fromLocal)
                let to = parse(time: toLocal)

                if isTime(localDeparture, insideFrom: from, to: to) {
                    return exactResult(
                        departureMinutes: localDeparture,
                        transportMinutes: rule.transportMinutes,
                        station: station
                    )
                }
            }

            return nil

        case "range":
            guard
                let min = station.defaultRule.minTransportMinutes,
                let max = station.defaultRule.maxTransportMinutes
            else {
                return nil
            }

            let pickupFrom = localDeparture - 60 - max
            let pickupTo = localDeparture - 60 - min

            let wakeupFrom = pickupFrom - 60
            let wakeupTo = pickupTo - 60

            return CalculationResult(
                pickup: "\(format(minutes: pickupFrom)) - \(format(minutes: pickupTo)) \(station.iata)",
                wakeup: "\(format(minutes: wakeupFrom)) - \(format(minutes: wakeupTo)) \(station.iata)"
            )

        default:
            return nil
        }
    }

    func exactResult(
        departureMinutes: Int,
        transportMinutes: Int,
        station: Station
    ) -> CalculationResult {

        let pickupMinutes = departureMinutes - 60 - transportMinutes
        let wakeupMinutes = pickupMinutes - 60

        return CalculationResult(
            pickup: "\(format(minutes: pickupMinutes)) \(station.iata)",
            wakeup: "\(format(minutes: wakeupMinutes)) \(station.iata)"
        )
    }

    func localDepartureMinutes(for station: Station) -> Int {
        guard let stationTimeZone = TimeZone(identifier: station.timeZone) else {
            return selectedHour * 60 + selectedMinute
        }

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        let today = Date()

        let utcDate = utcCalendar.date(
            from: DateComponents(
                timeZone: TimeZone(identifier: "UTC"),
                year: utcCalendar.component(.year, from: today),
                month: utcCalendar.component(.month, from: today),
                day: utcCalendar.component(.day, from: today),
                hour: selectedHour,
                minute: selectedMinute
            )
        ) ?? today

        let offsetMinutes = stationTimeZone.secondsFromGMT(for: utcDate) / 60

        return selectedHour * 60 + selectedMinute + offsetMinutes
    }

    func localDepartureLabel(for station: Station) -> String {
        let minutes = localDepartureMinutes(for: station)
        return "\(format(minutes: minutes)) \(station.iata)"
    }

    func isWeekendToday() -> Bool {
        let weekday = Calendar.current.component(.weekday, from: Date())
        return weekday == 1 || weekday == 7
    }

    func isTime(_ time: Int, insideFrom from: Int, to: Int) -> Bool {
        if from <= to {
            return time >= from && time <= to
        } else {
            return time >= from || time <= to
        }
    }

    func format(minutes: Int) -> String {
        let corrected = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", corrected / 60, corrected % 60)
    }

    func parse(time: String) -> Int {
        let parts = time.split(separator: ":")

        let hours = Int(parts[0]) ?? 0
        let minutes = Int(parts[1]) ?? 0

        return hours * 60 + minutes
    }
}

struct CalculationResult {
    let pickup: String
    let wakeup: String
}

#Preview {
    ContentView()
}
