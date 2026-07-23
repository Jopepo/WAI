import Foundation
import Testing
@testable import WAI

struct OperationalDataValidationTests {
    @Test func bundledCurrentTransportDataIsValid() throws {
        let data = try bundledData(named: "wai_transport_rules_current")
        let document = try JSONDecoder().decode(StationData.self, from: data)

        #expect(document.isValid)
    }

    @Test func rev74ContainsCurrentTransportChanges() throws {
        let data = try bundledData(named: "wai_transport_rules_current")
        let document = try JSONDecoder().decode(StationData.self, from: data)
        let cwb = try #require(document.stations.first { $0.iata == "CWB" })
        let ptp = try #require(document.stations.first { $0.iata == "PTP" })

        #expect(document.source?.revision == "REV74")
        #expect(cwb.defaultRule.type == "fixed")
        #expect(cwb.defaultRule.transportMinutes == 50)
        #expect(ptp.icao == "TFFR")
        #expect(ptp.defaultRule.transportMinutes == 60)
    }

    @Test func bundledCurrentHotelDataIsValid() throws {
        let data = try bundledData(named: "wai_hotel_map_current")
        let document = try JSONDecoder().decode(HotelDocument.self, from: data)
        let fra = try #require(document.hotels.first { $0.iata == "FRA" })
        let ptp = try #require(document.hotels.first { $0.iata == "PTP" })

        #expect(document.isValid)
        #expect(document.revision == "REV52")
        #expect(fra.name == "LEONARDO HOTEL MAINZ")
        #expect(ptp.name == "LA CRÉOLE BEACH HOTEL & SPA")
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
            maxVisibleItems: nil,
            items: []
        )

        #expect(!document.isValid)
    }

    @Test func whatsNewValidationRejectsUnsafeVisibleItemCount() {
        let item = WhatsNewItem(
            id: "test",
            title: "Test",
            detail: "Test detail",
            priority: .low,
            category: .app,
            documentRevision: "TEST"
        )
        let document = WhatsNewDocument(
            source: nil,
            maxVisibleItems: -1,
            items: [item]
        )

        #expect(!document.isValid)
    }

    @Test func transportValidationRejectsUnsafeMinuteArithmetic() {
        let station = Station(
            iata: "BAD",
            icao: "XXXX",
            city: "Broken",
            country: "Nowhere",
            timeZone: "UTC",
            standardUtcOffset: "+00:00",
            summerUtcOffset: "+00:00",
            defaultRule: TransportRule(
                type: "fixed",
                label: nil,
                transportMinutes: Int.max,
                minTransportMinutes: nil,
                maxTransportMinutes: nil,
                rules: nil,
                conditions: nil
            ),
            alternatives: [],
            holidays: nil
        )

        #expect(!StationData(source: nil, stations: [station]).isValid)
    }

    @Test func transportValidationRejectsMalformedIdentifiersAndOffsets() {
        let invalidStations = [
            validStation(iata: "lis"),
            validStation(icao: "LP P"),
            validStation(standardUTCOffset: "+14:30"),
            validStation(summerUTCOffset: "1:00")
        ]

        for station in invalidStations {
            #expect(!StationData(source: nil, stations: [station]).isValid)
        }
    }

    @Test func transportValidationRejectsAmbiguousRuleConditions() {
        let incompleteWindow = TransportCondition(
            label: "Incomplete",
            fromLocal: "08:00",
            toLocal: nil,
            appliesOnWeekdays: nil,
            appliesOnWeekends: nil,
            appliesOnPublicHolidays: nil,
            transportMinutes: 30
        )
        let conflictingFlags = TransportCondition(
            label: "Conflicting",
            fromLocal: nil,
            toLocal: nil,
            appliesOnWeekdays: true,
            appliesOnWeekends: true,
            appliesOnPublicHolidays: nil,
            transportMinutes: 30
        )

        #expect(!incompleteWindow.isValid)
        #expect(!conflictingFlags.isValid)
    }

    @Test func transportValidationRejectsDuplicateAlternativeLabels() {
        let alternative = TransportAlternative(
            label: "Crew bus",
            transportMinutes: 20
        )
        let station = validStation(alternatives: [alternative, alternative])

        #expect(!StationData(source: nil, stations: [station]).isValid)
    }

    @Test func operationalDatesMustBeRealAndExact() {
        #expect(!TransportTimeFormat.isValidISODate("2026-02-31"))
        #expect(!TransportTimeFormat.isValidISODate("2026-7-15"))
        #expect(TransportTimeFormat.isValidISODate("2026-07-15"))
    }

    @Test func hotelValidationRejectsMalformedCodesAndEmptyContactFields() {
        let malformedCode = Hotel(
            iata: "lis",
            icao: "LPPT",
            city: "Lisbon",
            country: "Portugal",
            name: "Test Hotel",
            phone: nil,
            email: nil,
            fax: nil
        )
        let emptyContact = Hotel(
            iata: "LIS",
            icao: "LPPT",
            city: "Lisbon",
            country: "Portugal",
            name: "Test Hotel",
            phone: "   ",
            email: nil,
            fax: nil
        )

        #expect(!hotelDocument(with: malformedCode).isValid)
        #expect(!hotelDocument(with: emptyContact).isValid)
    }

    @Test func whatsNewValidationRejectsWhitespaceOnlyTextAndInvalidSource() {
        let whitespaceItem = WhatsNewItem(
            id: "test",
            title: "   ",
            detail: "Test detail",
            priority: .low,
            category: .app,
            documentRevision: "TEST"
        )
        let invalidSource = OperationalDataDocumentSource(
            document: "Test",
            revision: "   ",
            date: "2026-07-15"
        )

        #expect(!WhatsNewDocument(
            source: nil,
            maxVisibleItems: 1,
            items: [whitespaceItem]
        ).isValid)
        #expect(!WhatsNewDocument(
            source: invalidSource,
            maxVisibleItems: 1,
            items: [validWhatsNewItem()]
        ).isValid)
    }

    private func validStation(
        iata: String = "TST",
        icao: String = "TEST",
        standardUTCOffset: String = "+00:00",
        summerUTCOffset: String = "+00:00",
        alternatives: [TransportAlternative] = []
    ) -> Station {
        Station(
            iata: iata,
            icao: icao,
            city: "Test City",
            country: "Testland",
            timeZone: "UTC",
            standardUtcOffset: standardUTCOffset,
            summerUtcOffset: summerUTCOffset,
            defaultRule: TransportRule(
                type: "fixed",
                label: nil,
                transportMinutes: 30,
                minTransportMinutes: nil,
                maxTransportMinutes: nil,
                rules: nil,
                conditions: nil
            ),
            alternatives: alternatives,
            holidays: nil
        )
    }

    private func hotelDocument(with hotel: Hotel) -> HotelDocument {
        HotelDocument(
            document: "Test",
            revision: "TEST",
            date: "2026-07-15",
            hotels: [hotel]
        )
    }

    private func validWhatsNewItem() -> WhatsNewItem {
        WhatsNewItem(
            id: "test",
            title: "Test",
            detail: "Test detail",
            priority: .low,
            category: .app,
            documentRevision: "TEST"
        )
    }

    private func bundledData(named resourceName: String) throws -> Data {
        let url = try #require(Bundle.main.url(forResource: resourceName, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
