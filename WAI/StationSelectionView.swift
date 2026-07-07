import SwiftUI

struct StationSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedStation: String
    @State private var searchText = ""

    let stations: [Station]

    private var filteredStations: [Station] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sortedStations = stations.sorted { $0.iata < $1.iata }

        guard !query.isEmpty else {
            return sortedStations
        }

        return sortedStations.filter { station in
            station.iata.lowercased().contains(query)
            || station.icao.lowercased().contains(query)
            || station.city.lowercased().contains(query)
            || station.country.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if selectedStation != "WhereAmI?" {
                    Section {
                        Button {
                            selectedStation = "WhereAmI?"
                            dismiss()
                        } label: {
                            Label("Clear station", systemImage: "xmark.circle")
                        }
                    }
                }

                Section {
                    if filteredStations.isEmpty {
                        emptyState
                    } else {
                        ForEach(filteredStations) { station in
                            Button {
                                selectedStation = station.iata
                                dismiss()
                            } label: {
                                stationRow(station)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Select Station")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search IATA, city, country")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No stations found")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Try searching by IATA, ICAO, city, or country.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func stationRow(_ station: Station) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(station.iata)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
                .frame(width: 46, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(station.city)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                Text("\(station.icao) · \(station.country)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if selectedStation == station.iata {
                Image(systemName: "checkmark")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.blue)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    StationSelectionView(
        selectedStation: .constant("OPO"),
        stations: DataService.loadStations()
    )
}
