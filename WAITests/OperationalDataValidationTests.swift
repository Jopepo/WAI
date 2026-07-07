import Foundation
import Testing
@testable import WAI

struct OperationalDataValidationTests {
    @Test func bundledCurrentTransportDataIsValid() throws {
        let data = try bundledData(named: "wai_transport_rules_current")
        let document = try JSONDecoder().decode(StationData.self, from: data)

        #expect(document.isValid)
    }

    @Test func bundledCurrentHotelDataIsValid() throws {
        let data = try bundledData(named: "wai_hotel_map_current")
        let document = try JSONDecoder().decode(HotelDocument.self, from: data)

        #expect(document.isValid)
    }

    @Test func bundledCurrentWhatsNewDataIsValid() throws {
        let data = try bundledData(named: "wai_whats_new_current")
        let document = try JSONDecoder().decode(WhatsNewDocument.self, from: data)

        #expect(document.isValid)
    }

    @Test func transportValidationRejectsEmptyStationList() {
        let document = StationData(source: nil, stations: [])

        #expect(!document.isValid)
    }

    @Test func transportValidationRejectsInvalidTimeZone() {
        let station = Station(
            iata: "BAD",
            icao: "XXXX",
            city: "Broken",
            country: "Nowhere",
            timeZone: "Invalid/Zone",
            standardUtcOffset: "+00:00",
            summerUtcOffset: "+00:00",
            defaultRule: TransportRule(
                type: "fixed",
                label: nil,
                transportMinutes: 30,
                minTransportMinutes: nil,
                maxTransportMinutes: nil,
                rules: nil,
                conditions: nil
            ),
            alternatives: [],
            holidays: nil
        )
        let document = StationData(source: nil, stations: [station])

        #expect(!document.isValid)
    }

    @Test func hotelValidationRejectsDuplicateIATA() {
        let hotel = Hotel(
            iata: "OPO",
            icao: "LPPR",
            city: "Porto",
            country: "Portugal",
            name: "Example Hotel",
            phone: nil,
            email: nil,
            fax: nil
        )
        let document = HotelDocument(
            document: "Test",
            revision: "TEST",
            date: "2026-07-07",
            hotels: [hotel, hotel]
        )

        #expect(!document.isValid)
    }

    @Test func whatsNewValidationRejectsEmptyItems() {
        let document = WhatsNewDocument(
            source: OperationalDataDocumentSource(
                document: "Test",
                revision: "TEST",
                date: "2026-07-07"
            ),
            items: []
        )

        #expect(!document.isValid)
    }

    private func bundledData(named resourceName: String) throws -> Data {
        let url = try #require(Bundle.main.url(forResource: resourceName, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
