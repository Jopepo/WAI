import Foundation

struct StationData: Codable {
    let stations: [Station]
}

final class DataService {

    static func loadStations() -> [Station] {

        guard let url = Bundle.main.url(
            forResource: "wai_transport_rules_v5_2",
            withExtension: "json"
        ) else {

            print("JSON file not found")
            return []
        }

        do {

            let data = try Data(contentsOf: url)

            let decoded = try JSONDecoder().decode(
                StationData.self,
                from: data
            )

            print("Loaded \(decoded.stations.count) stations")

            return decoded.stations

        } catch {

            print("FULL ERROR:")
            dump(error)

            return []
        }
    }
}
