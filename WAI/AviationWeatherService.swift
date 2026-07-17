import Foundation

struct AviationWeatherReport: Decodable, Equatable, Sendable, Identifiable {
    let icaoID: String
    let rawObservation: String
    let observationTime: Date?
    let temperatureCelsius: Double?
    let dewpointCelsius: Double?
    let windDirectionDegrees: Int?
    let windSpeedKnots: Int?
    let windGustKnots: Int?
    let visibility: String?
    let altimeterHPa: Double?
    let flightCategory: String?

    var id: String { icaoID }

    private enum CodingKeys: String, CodingKey {
        case icaoID = "icaoId"
        case rawObservation = "rawOb"
        case observationTime = "obsTime"
        case temperatureCelsius = "temp"
        case dewpointCelsius = "dewp"
        case windDirectionDegrees = "wdir"
        case windSpeedKnots = "wspd"
        case windGustKnots = "wgst"
        case visibility = "visib"
        case altimeterHPa = "altim"
        case flightCategory = "fltCat"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        icaoID = try values.decode(String.self, forKey: .icaoID)
        rawObservation = try values.decode(String.self, forKey: .rawObservation)
        observationTime = Self.decodeDate(values, key: .observationTime)
        temperatureCelsius = Self.decodeDouble(values, key: .temperatureCelsius)
        dewpointCelsius = Self.decodeDouble(values, key: .dewpointCelsius)
        windDirectionDegrees = Self.decodeInt(values, key: .windDirectionDegrees)
        windSpeedKnots = Self.decodeInt(values, key: .windSpeedKnots)
        windGustKnots = Self.decodeInt(values, key: .windGustKnots)
        visibility = try? values.decode(String.self, forKey: .visibility)
        altimeterHPa = Self.decodeDouble(values, key: .altimeterHPa)
        flightCategory = try? values.decode(String.self, forKey: .flightCategory)
    }

    private static func decodeDate(
        _ values: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Date? {
        if let seconds = decodeDouble(values, key: key) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let text = try? values.decode(String.self, forKey: key) {
            return ISO8601DateFormatter().date(from: text)
        }
        return nil
    }

    private static func decodeDouble(
        _ values: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Double? {
        if let number = try? values.decode(Double.self, forKey: key) {
            return number
        }
        if let text = try? values.decode(String.self, forKey: key) {
            return Double(text)
        }
        return nil
    }

    private static func decodeInt(
        _ values: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int? {
        decodeDouble(values, key: key).map { Int($0.rounded()) }
    }
}

enum AviationWeatherServiceError: Error, Equatable {
    case invalidStation
    case invalidResponse
    case noData
}

private actor AviationWeatherMemoryCache {
    static let shared = AviationWeatherMemoryCache()

    private struct Entry {
        let report: AviationWeatherReport
        let fetchedAt: Date
    }

    private var entries: [String: Entry] = [:]

    func reports(for stations: [String], now: Date = Date())
        -> [AviationWeatherReport]?
    {
        let matching = stations.compactMap { entries[$0] }
        guard matching.count == stations.count,
              matching.allSatisfy({
                  now.timeIntervalSince($0.fetchedAt) < 60
              }) else {
            return nil
        }
        return matching.map(\.report)
    }

    func store(_ reports: [AviationWeatherReport], now: Date = Date()) {
        for report in reports {
            entries[report.icaoID] = Entry(report: report, fetchedAt: now)
        }
    }
}

struct AviationWeatherService {
    private static let endpoint = URL(
        string: "https://aviationweather.gov/api/data/metar"
    )!

    static func reports(for icaoCodes: [String]) async throws
        -> [AviationWeatherReport]
    {
        let stations = Array(
            Set(icaoCodes.map { $0.uppercased() })
        ).sorted()
        guard !stations.isEmpty,
              stations.count <= 10,
              stations.allSatisfy({ code in
                  code.utf8.count == 4
                  && code.utf8.allSatisfy { byte in
                      (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                  }
              }) else {
            throw AviationWeatherServiceError.invalidStation
        }
        if let cached = await AviationWeatherMemoryCache.shared.reports(
            for: stations
        ) {
            return cached
        }

        var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "ids", value: stations.joined(separator: ",")),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else {
            throw AviationWeatherServiceError.invalidStation
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue("WAI/3.0 aviation-weather", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await WAIPrivateNetworkSession.boundedData(
            for: request,
            maximumBytes: 256_000
        )
        guard let response = response as? HTTPURLResponse else {
            throw AviationWeatherServiceError.invalidResponse
        }
        if response.statusCode == 204 {
            throw AviationWeatherServiceError.noData
        }
        guard response.statusCode == 200 else {
            throw AviationWeatherServiceError.invalidResponse
        }
        let reports = try JSONDecoder().decode(
            [AviationWeatherReport].self,
            from: data
        )
        guard !reports.isEmpty else {
            throw AviationWeatherServiceError.noData
        }
        await AviationWeatherMemoryCache.shared.store(reports)
        return reports
    }
}
