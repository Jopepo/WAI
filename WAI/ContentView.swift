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
    @State private var etdDate = Date()
    @AppStorage("wai.timeInputReference") private var timeInputReferenceRawValue = TimeInputReference.utc.rawValue
    @State private var showingTimePicker = false
    @State private var selectedAlternative = "__DEFAULT__"
    @State private var showingFeedbackFallback = false
    @State private var showingSettings = false
    @State private var showingHistory = false
    @State private var showingWhatsNew = false
    @State private var showingFlightDetails = false
    @State private var didSaveCalculation = false
    @State private var isReadyToCalculate = false
    @State private var selectedHotel: Hotel?
    @StateObject private var historyStore = CalculationHistoryStore()

    var timeInputReference: TimeInputReference {
        TimeInputReference(rawValue: timeInputReferenceRawValue) ?? .utc
    }

    var formattedTime: String {
        String(format: "%02d:%02d", selectedHour, selectedMinute)
    }

    var selectedStationObject: Station? {
        stations.first { $0.iata == selectedStation }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    topBar

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
                        showingFlightDetails = false
                        isReadyToCalculate = false
                        didSaveCalculation = false
                    }

                    if selectedStation != "WhereAmI?" {
                        if !isReadyToCalculate {
                            timeInputView
                        }

                        if let station = selectedStationObject {
                            if !isReadyToCalculate {
                                transportOptionView(for: station)
                                calculateButton
                            }

                            if isReadyToCalculate {
                                resultsView(for: station)
                            }
                        }
                    }

                    Spacer(minLength: 40)

                    bottomInfoSection
                }
                .padding()
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(timeInputReferenceRawValue: $timeInputReferenceRawValue)
        }
        .onChange(of: showingSettings) {
            if !showingSettings {
                didSaveCalculation = false
            }
        }
        .sheet(isPresented: $showingHistory) {
            NavigationStack {
                ScrollView {
                    historySection
                        .padding(.top)
                }
                .navigationTitle("Saved Calculations")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            showingHistory = false
                        }
                    }
                }
            }
        }
        .onChange(of: showingHistory) {
            if !showingHistory {
                didSaveCalculation = false
            }
        }
        .sheet(isPresented: $showingWhatsNew) {
            WhatsNewView()
        }
        .onChange(of: showingWhatsNew) {
            if !showingWhatsNew {
                didSaveCalculation = false
            }
        }
        .sheet(item: $selectedHotel) { hotel in
            HotelDetailView(hotel: hotel)
        }
    }

    var timeInputView: some View {
        VStack(spacing: 12) {
            Text("Flight Departure")
                .font(.headline)

            Button {
                showingTimePicker.toggle()
                isReadyToCalculate = false
            } label: {
                Text(formattedTime)
                    .font(.title2)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            DatePicker(
                "",
                selection: $etdDate,
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .onChange(of: etdDate) {
                isReadyToCalculate = false
                showingFlightDetails = false
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
                        .onChange(of: selectedHour) {
                            isReadyToCalculate = false
                            showingFlightDetails = false
                        }

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
                        .onChange(of: selectedMinute) {
                            isReadyToCalculate = false
                            showingFlightDetails = false
                        }
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

    var calculateButton: some View {
        Button {
            showingTimePicker = false
            showingFlightDetails = false
            isReadyToCalculate = true
        } label: {
            Label("Calculate", systemImage: "checkmark.circle")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal)
    }

    func transportOptionView(for station: Station) -> some View {
        Group {
            if !station.alternatives.isEmpty {
                VStack(spacing: 12) {
                    Text("Transport option")
                        .font(.headline)

                    Picker("Transport option", selection: $selectedAlternative) {
                        Text(defaultTransportOptionLabel(for: station)).tag(defaultAlternativeTag)

                        ForEach(station.alternatives) { alternative in
                            Text(alternative.label).tag(alternative.label)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedAlternative) {
                        isReadyToCalculate = false
                        showingFlightDetails = false
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    var bottomInfoSection: some View {
        VStack(spacing: 12) {
            Text("Transport Times: REV70 · 29 Jun 2026")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.gray.opacity(0.12))
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    var historySection: some View {
        VStack(spacing: 12) {
            if historyStore.history.isEmpty {
                VStack(spacing: 8) {
                    Text("No saved calculations yet")
                        .font(.headline)

                    Text("Saved calculations will appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            } else {
                VStack(spacing: 10) {
                    ForEach(historyStore.history) { item in
                        HStack(alignment: .top, spacing: 12) {
                            historyRow(item)

                            Button(role: .destructive) {
                                historyStore.delete(item)
                                didSaveCalculation = false
                            } label: {
                                Image(systemName: "trash")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete calculation")
                        }
                        .padding(.vertical, 4)

                        if item.id != historyStore.history.last?.id {
                            Divider()
                        }
                    }

                    Button("Clear calculations", role: .destructive) {
                        historyStore.clearHistory()
                        didSaveCalculation = false
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 6)
                }
                .padding()
                .background(.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
        }
        .padding(.horizontal)
    }

    func historyRow(_ item: CalculationHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(item.stationIATA) - \(item.stationCity)")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("ETD: \(formatHistoryDate(item.etdDate)) · \(item.inputTimeText) · \(item.inputReference.title)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Wake-up: \(item.wakeupTimeText)")
                .font(.caption)

            Text("Pick-up: \(item.pickupTimeText)")
                .font(.caption)

            if let appliedRuleLabel = item.appliedRuleLabel {
                Text("Rule: \(appliedRuleLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

            if let result = calculateResult(for: station) {
                resultCard(result, station: station, hotel: hotel(for: station))
            } else {
                errorCard
            }
        }
        .padding(.horizontal)
    }

    func flightConversionCard(for station: Station) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut) {
                    showingFlightDetails.toggle()
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Flight time")
                            .font(.headline)

                        Text("\(formattedETDDate) · \(formattedTime) · \(timeInputReference.title)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: showingFlightDetails ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showingFlightDetails {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Converted time")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    ForEach(convertedDepartureRows(for: station), id: \.self) { row in
                        Text(row)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.gray.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    var topBar: some View {
        HStack(spacing: 12) {
            Spacer()

            Button {
                showingWhatsNew = true
            } label: {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(.gray.opacity(0.10))
                    .clipShape(Circle())
            }
            .accessibilityLabel("What's New")

            Button {
                showingHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(.gray.opacity(0.10))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Saved Calculations")

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(.gray.opacity(0.10))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal)
    }

    func resultCard(_ result: CalculationResult, station: Station, hotel: Hotel?) -> some View {
        VStack(spacing: 14) {
            Text("Transport time used: \(result.transportTime)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let appliedRuleLabel = result.appliedRuleLabel {
                Text("Rule: \(appliedRuleLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            hotelCard(for: station, hotel: hotel)

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

            HStack(spacing: 12) {
                Button {
                    resetCalculatorForNextInput()
                } label: {
                    Label("Dismiss", systemImage: "xmark.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    saveCalculation(result, for: station)
                    didSaveCalculation = true

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        resetCalculatorForNextInput()
                    }
                } label: {
                    Label(
                        didSaveCalculation ? "Saved!" : "Save calculation",
                        systemImage: didSaveCalculation ? "checkmark.circle.fill" : "tray.and.arrow.down"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
    func hotelCard(for station: Station, hotel: Hotel?) -> some View {
        Group {
            if let hotel {
                Button {
                    selectedHotel = hotel
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hotel")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text(hotel.name)
                                .font(.headline)
                                .multilineTextAlignment(.leading)

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding()
                .background(.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hotel")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Hotel info unavailable for \(station.iata)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    func defaultTransportOptionLabel(for station: Station) -> String {
        if let hotel = hotel(for: station) {
            return hotel.name
        }

        return "Default"
    }

    func hotel(for station: Station) -> Hotel? {
        HotelDataService.shared.hotel(for: station.iata.uppercased())
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
        return TimeCalculator.calculate(
            selectedHour: selectedHour,
            selectedMinute: selectedMinute,
            station: station,
            selectedAlternative: selectedAlternative,
            defaultAlternativeTag: defaultAlternativeTag,
            inputReference: timeInputReference,
            etdDate: etdDate,
            stationHolidays: station.holidays ?? []
        )
    }



    func saveCalculation(_ result: CalculationResult, for station: Station) {
        let item = CalculationHistoryItem(
            stationIATA: station.iata,
            stationCity: station.city,
            etdDate: etdDate,
            inputReference: timeInputReference,
            inputTimeText: String(format: "%02d:%02d", selectedHour, selectedMinute),
            pickupTimeText: result.pickup,
            wakeupTimeText: result.wakeup,
            appliedRuleLabel: result.appliedRuleLabel
        )

        historyStore.save(item)
    }

    func resetCalculatorForNextInput() {
        selectedStation = "WhereAmI?"
        selectedHour = 6
        selectedMinute = 0
        etdDate = Date()
        showingTimePicker = false
        selectedAlternative = defaultAlternativeTag
        showingFlightDetails = false
        isReadyToCalculate = false
        selectedHotel = nil
        didSaveCalculation = false
    }

    func localDepartureLabel(for station: Station) -> String {
        TimeCalculator.localDepartureLabel(
            selectedHour: selectedHour,
            selectedMinute: selectedMinute,
            station: station,
            inputReference: timeInputReference,
            etdDate: etdDate
        )
    }
    func convertedDepartureRows(for station: Station) -> [String] {
        localDepartureLabel(for: station)
            .components(separatedBy: " / ")
    }
    var feedbackMailtoURL: URL {
        let subject = "WAI Feedback"
        let station = selectedStation == "WhereAmI?" ? "No station selected" : selectedStation
        let body = """
        Hi João,

        I want to send feedback about WAI.

        Station: \(station)
        Departure date: \(formattedETDDate)
        Departure time: \(formattedTime)
        App version: \(appVersionLabel)

        Feedback / bug:

        """

        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
        let urlString = "mailto:joao.p.possidonio@gmail.com?subject=\(encodedSubject)&body=\(encodedBody)"

        return URL(string: urlString) ?? URL(string: "mailto:joao.p.possidonio@gmail.com")!
    }

    var formattedETDDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: etdDate)
    }

    func formatHistoryDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
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
