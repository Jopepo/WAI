import SwiftUI

struct HotelsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dataService = DataService.shared
    @StateObject private var hotelDataService = HotelDataService.shared
    @State private var searchText = ""
    @State private var selectedHotel: Hotel?

    private var availableHotels: [Hotel] {
        let stationIATAs = Set(dataService.stations.map { $0.iata.uppercased() })

        return hotelDataService.hotels
            .filter { stationIATAs.contains($0.iata.uppercased()) }
            .sorted { lhs, rhs in
                if lhs.iata == rhs.iata {
                    return lhs.displayName < rhs.displayName
                }

                return lhs.iata < rhs.iata
            }
    }

    private var filteredHotels: [Hotel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !query.isEmpty else {
            return availableHotels
        }

        return availableHotels.filter { hotel in
            hotel.iata.lowercased().contains(query)
            || hotel.icao.lowercased().contains(query)
            || hotel.city.lowercased().contains(query)
            || hotel.country.lowercased().contains(query)
            || hotel.displayName.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    summaryRow
                }

                Section {
                    if filteredHotels.isEmpty {
                        emptyState
                    } else {
                        ForEach(filteredHotels) { hotel in
                            Button {
                                selectedHotel = hotel
                            } label: {
                                hotelRow(hotel)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Hotels")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search IATA, city, hotel")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(item: $selectedHotel) { hotel in
            HotelDetailView(hotel: hotel)
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "bed.double")
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(availableHotels.count) hotels available")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("Only stations with transport rules are shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No hotels found")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Try searching by IATA, city, country, or hotel name.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func hotelRow(_ hotel: Hotel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(hotel.iata)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
                .frame(width: 44, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(hotel.displayName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                Text("\(hotel.city), \(hotel.country)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 3)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    HotelsView()
}
