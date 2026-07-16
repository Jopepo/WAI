import CryptoKit
import Foundation

enum TAPRosterParserError: Error, Equatable {
    case invalidEncoding
    case malformedCalendar
    case unsupportedCompany
    case noEvents
    case duplicateDutyID(String)
    case invalidEvent(dutyID: String, field: String)
    case invalidFlight(dutyID: String, flightNumber: String, field: String)
    case invalidDocument
}

struct TAPRosterParser {
    static func parse(
        data: Data,
        sourceName: String? = nil,
        stationTimeZones: [String: String],
        importedAt: Date = Date()
    ) throws -> RosterImportResult {
        guard let text = String(data: data, encoding: .utf8) else {
            throw TAPRosterParserError.invalidEncoding
        }

        let calendar = try ICalendarSubsetParser.parse(text)
        guard !calendar.events.isEmpty else {
            throw TAPRosterParserError.noEvents
        }

        let productIdentifier = calendar.firstText("PRODID")
        let calendarName = calendar.firstText("X-WR-CALNAME")
        let calendarDescription = calendar.firstText("X-WR-CALDESC")
        guard identifiesTAP(
            productIdentifier: productIdentifier,
            calendarName: calendarName
        ) else {
            throw TAPRosterParserError.unsupportedCompany
        }

        let calendarTimeZone = calendar.firstRaw("X-WR-TIMEZONE")
        let normalizedStationTimeZones = normalizedTimeZones(
            stationTimeZones
        )
        var issues: [RosterImportIssue] = []
        var seenDutyIDs = Set<String>()
        var duties: [RosterDuty] = []

        for event in calendar.events {
            let duty = try parseEvent(
                event,
                calendarTimeZone: calendarTimeZone,
                stationTimeZones: normalizedStationTimeZones,
                issues: &issues
            )
            guard seenDutyIDs.insert(duty.id).inserted else {
                throw TAPRosterParserError.duplicateDutyID(duty.id)
            }
            duties.append(duty)
        }

        duties.sort {
            if $0.start == $1.start {
                return $0.id < $1.id
            }
            return $0.start < $1.start
        }

        guard let firstDuty = duties.first,
              let lastDuty = duties.last else {
            throw TAPRosterParserError.noEvents
        }

        let eventTimeZoneIdentifier = calendar.events.compactMap { event in
            normalizedOptional(event.firstRaw("TZID"))
                .flatMap(normalizedICalendarTimeZone)
        }.first
        let coverageTimeZoneIdentifier = normalizedOptional(
            calendarTimeZone
        )
        .flatMap(normalizedICalendarTimeZone)
            ?? eventTimeZoneIdentifier
            ?? firstDuty.timeZoneIdentifier
        let coverage = parseCoverage(
            calendarName: calendarName,
            timeZoneIdentifier: coverageTimeZoneIdentifier
        ) ?? RosterCoveragePeriod(
            start: firstDuty.start,
            end: duties.map(\.end).max() ?? lastDuty.end,
            timeZoneIdentifier: coverageTimeZoneIdentifier
        )

        let source = RosterSource(
            company: .tap,
            productIdentifier: productIdentifier,
            calendarName: calendarName,
            crewIdentifier: parseCrewIdentifier(calendarDescription),
            sourceName: normalizedOptional(sourceName),
            sha256: SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined(),
            importedAt: importedAt
        )
        let document = RosterDocument(
            source: source,
            coverage: coverage,
            duties: duties
        )
        guard document.isValid else {
            throw TAPRosterParserError.invalidDocument
        }

        return RosterImportResult(
            document: document,
            issues: Array(Set(issues)).sorted { $0.id < $1.id }
        )
    }

    private static func parseEvent(
        _ event: ICalendarRawEvent,
        calendarTimeZone: String?,
        stationTimeZones: [String: String],
        issues: inout [RosterImportIssue]
    ) throws -> RosterDuty {
        let dutyID = try requiredText("UID", event: event, dutyID: "unknown")
        let summary = try requiredText("SUMMARY", event: event, dutyID: dutyID)
        let description = event.firstText("DESCRIPTION") ?? ""
        let activityCode = parseActivityCode(description) ?? summary
        guard let normalizedActivity = normalizedOptional(activityCode) else {
            throw TAPRosterParserError.invalidEvent(
                dutyID: dutyID,
                field: "activity code"
            )
        }

        let hotelCode = parseHotelCode(description)
        let flightBlocks = splitFlightBlocks(description)
        var legs: [RosterLeg] = []
        for (index, block) in flightBlocks.enumerated() {
            legs.append(
                try parseFlightBlock(
                    block,
                    dutyID: dutyID,
                    index: index,
                    stationTimeZones: stationTimeZones,
                    issues: &issues
                )
            )
        }

        let eventTimeZone = normalizedOptional(event.firstRaw("TZID"))
        let startProperty = try requiredProperty(
            "DTSTART",
            event: event,
            dutyID: dutyID
        )
        let endProperty = try requiredProperty(
            "DTEND",
            event: event,
            dutyID: dutyID
        )

        // Portal DOV exports floating wall times for flight boundaries. The
        // event-level TZID remains Lisbon even when a duty starts or ends at
        // another station, so endpoint stations are the authoritative
        // fallback. Explicit DTSTART/DTEND parameters and UTC values still
        // take precedence inside parseICalendarDate.
        let startFallbackTimeZone = legs.first.flatMap {
            stationTimeZones[$0.originIATA]
        } ?? eventTimeZone ?? calendarTimeZone
        let endFallbackTimeZone = legs.last.flatMap {
            stationTimeZones[$0.destinationIATA]
        } ?? eventTimeZone ?? calendarTimeZone
        let start = try parseICalendarDate(
            startProperty,
            fallbackTimeZone: startFallbackTimeZone,
            dutyID: dutyID,
            field: "DTSTART"
        )
        let end = try parseICalendarDate(
            endProperty,
            fallbackTimeZone: endFallbackTimeZone,
            dutyID: dutyID,
            field: "DTEND"
        )
        guard start.date < end.date else {
            throw TAPRosterParserError.invalidEvent(
                dutyID: dutyID,
                field: "date range"
            )
        }

        return RosterDuty(
            id: dutyID,
            activityCode: normalizedActivity,
            start: start.date,
            end: end.date,
            timeZoneIdentifier: start.timeZoneIdentifier,
            kind: legs.isEmpty ? .activity : .flight,
            hotelCode: hotelCode,
            legs: legs
        )
    }

    private static func parseFlightBlock(
        _ lines: [String],
        dutyID: String,
        index: Int,
        stationTimeZones: [String: String],
        issues: inout [RosterImportIssue]
    ) throws -> RosterLeg {
        guard let firstLine = lines.first else {
            throw TAPRosterParserError.invalidFlight(
                dutyID: dutyID,
                flightNumber: "unknown",
                field: "flight block"
            )
        }

        let flightNumber = firstLine
            .dropFirst(min(firstLine.count, 4))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
        guard isValidFlightNumber(flightNumber) else {
            throw TAPRosterParserError.invalidFlight(
                dutyID: dutyID,
                flightNumber: flightNumber,
                field: "flight number"
            )
        }

        let departureValue = try requiredLabeledValue(
            "SAIDA",
            lines: lines,
            dutyID: dutyID,
            flightNumber: flightNumber
        )
        let arrivalValue = try requiredLabeledValue(
            "CHEGADA",
            lines: lines,
            dutyID: dutyID,
            flightNumber: flightNumber
        )
        let originValue = try requiredLabeledValue(
            "ORIGEM",
            lines: lines,
            dutyID: dutyID,
            flightNumber: flightNumber
        )
        let destinationValue = try requiredLabeledValue(
            "DESTINO",
            lines: lines,
            dutyID: dutyID,
            flightNumber: flightNumber
        )

        let origin = try parseAirport(
            originValue,
            dutyID: dutyID,
            flightNumber: flightNumber,
            field: "origin"
        )
        let destination = try parseAirport(
            destinationValue,
            dutyID: dutyID,
            flightNumber: flightNumber,
            field: "destination"
        )
        let departureComponents = try parseTAPLocalDateTime(
            departureValue,
            dutyID: dutyID,
            flightNumber: flightNumber,
            field: "departure"
        )
        let arrivalComponents = try parseTAPLocalDateTime(
            arrivalValue,
            dutyID: dutyID,
            flightNumber: flightNumber,
            field: "arrival"
        )

        let departure = try resolveLocalDateTime(
            departureComponents,
            stationIATA: origin.iata,
            stationTimeZones: stationTimeZones,
            dutyID: dutyID,
            flightNumber: flightNumber,
            field: "departure",
            issues: &issues
        )
        let arrival = try resolveLocalDateTime(
            arrivalComponents,
            stationIATA: destination.iata,
            stationTimeZones: stationTimeZones,
            dutyID: dutyID,
            flightNumber: flightNumber,
            field: "arrival",
            issues: &issues
        )
        if let departureInstant = departure.instant,
           let arrivalInstant = arrival.instant,
           arrivalInstant <= departureInstant {
            throw TAPRosterParserError.invalidFlight(
                dutyID: dutyID,
                flightNumber: flightNumber,
                field: "date range"
            )
        }

        let aircraft = parseAircraft(labeledValue("MATRICULA", lines: lines))
        let passengerLoad = normalizedOptional(labeledValue("PAX", lines: lines))
        let radiation = parseDouble(
            labeledValue("RADIACAO COSMICA", lines: lines)
        )
        let crew = parseCrew(lines)

        return RosterLeg(
            id: "\(dutyID)-\(index)-\(flightNumber)",
            flightNumber: flightNumber,
            departure: departure,
            arrival: arrival,
            originIATA: origin.iata,
            originName: origin.name,
            destinationIATA: destination.iata,
            destinationName: destination.name,
            aircraftRegistration: aircraft.registration,
            aircraftName: aircraft.name,
            passengerLoad: passengerLoad,
            cosmicRadiation: radiation,
            crew: crew
        )
    }

    private static func parseCoverage(
        calendarName: String?,
        timeZoneIdentifier: String
    ) -> RosterCoveragePeriod? {
        guard let calendarName,
              let timeZone = TimeZone(identifier: timeZoneIdentifier),
              let captures = captures(
                pattern: "(\\d{2})-(\\d{2})-(\\d{4})\\s+[aA]\\s+(\\d{2})-(\\d{2})-(\\d{4})",
                in: calendarName
              ),
              captures.count == 6 else {
            return nil
        }

        let values = captures.compactMap(Int.init)
        guard values.count == 6,
              let start = resolve(
                year: values[2],
                month: values[1],
                day: values[0],
                hour: 0,
                minute: 0,
                in: timeZone
              ),
              let inclusiveEnd = resolve(
                year: values[5],
                month: values[4],
                day: values[3],
                hour: 0,
                minute: 0,
                in: timeZone
              ) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let end = calendar.date(byAdding: .day, value: 1, to: inclusiveEnd),
              start < end else {
            return nil
        }

        return RosterCoveragePeriod(
            start: start,
            end: end,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    private static func parseICalendarDate(
        _ property: ICalendarRawProperty,
        fallbackTimeZone: String?,
        dutyID: String,
        field: String
    ) throws -> (date: Date, timeZoneIdentifier: String) {
        let raw = property.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let isUTC = raw.hasSuffix("Z")
        let value = isUTC ? String(raw.dropLast()) : raw
        let components: (Int, Int, Int, Int, Int)

        if value.count == 8 {
            guard let parsed = parseDigitsDate(value, includesTime: false) else {
                throw TAPRosterParserError.invalidEvent(dutyID: dutyID, field: field)
            }
            components = parsed
        } else if value.count == 15, value[value.index(value.startIndex, offsetBy: 8)] == "T" {
            guard let parsed = parseDigitsDate(value, includesTime: true) else {
                throw TAPRosterParserError.invalidEvent(dutyID: dutyID, field: field)
            }
            components = parsed
        } else {
            throw TAPRosterParserError.invalidEvent(dutyID: dutyID, field: field)
        }

        let rawIdentifier = isUTC
            ? "UTC"
            : normalizedOptional(property.parameters["TZID"])
                ?? normalizedOptional(fallbackTimeZone)
        guard let rawIdentifier,
              let identifier = normalizedICalendarTimeZone(rawIdentifier),
              let timeZone = TimeZone(identifier: identifier),
              let date = resolve(
                year: components.0,
                month: components.1,
                day: components.2,
                hour: components.3,
                minute: components.4,
                in: timeZone
              ) else {
            throw TAPRosterParserError.invalidEvent(dutyID: dutyID, field: field)
        }

        return (date, identifier)
    }

    private static func normalizedICalendarTimeZone(
        _ value: String
    ) -> String? {
        let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if TimeZone(identifier: identifier) != nil {
            return identifier
        }

        let regions = [
            "Africa", "America", "Antarctica", "Arctic", "Asia",
            "Atlantic", "Australia", "Europe", "Indian", "Pacific"
        ]
        for region in regions {
            let prefix = "\(region)-"
            guard identifier.hasPrefix(prefix) else {
                continue
            }
            let candidate = "\(region)/\(identifier.dropFirst(prefix.count))"
            if TimeZone(identifier: candidate) != nil {
                return candidate
            }
        }
        return nil
    }

    private static func parseDigitsDate(
        _ value: String,
        includesTime: Bool
    ) -> (Int, Int, Int, Int, Int)? {
        let compact = includesTime
            ? value.replacingOccurrences(of: "T", with: "")
            : value
        guard compact.utf8.allSatisfy({ byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }), compact.count == (includesTime ? 14 : 8) else {
            return nil
        }

        func number(_ start: Int, _ length: Int) -> Int? {
            let lower = compact.index(compact.startIndex, offsetBy: start)
            let upper = compact.index(lower, offsetBy: length)
            return Int(compact[lower..<upper])
        }

        guard let year = number(0, 4),
              let month = number(4, 2),
              let day = number(6, 2) else {
            return nil
        }
        let hour = includesTime ? number(8, 2) : 0
        let minute = includesTime ? number(10, 2) : 0
        guard let hour, let minute else {
            return nil
        }
        return (year, month, day, hour, minute)
    }

    private static func parseTAPLocalDateTime(
        _ value: String,
        dutyID: String,
        flightNumber: String,
        field: String
    ) throws -> (year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        guard let values = captures(
            pattern: "(\\d{2})/(\\d{2})/(\\d{4})\\s*-\\s*(\\d{2}):(\\d{2})",
            in: value
        )?.compactMap(Int.init), values.count == 5 else {
            throw TAPRosterParserError.invalidFlight(
                dutyID: dutyID,
                flightNumber: flightNumber,
                field: field
            )
        }
        return (values[2], values[1], values[0], values[3], values[4])
    }

    private static func resolveLocalDateTime(
        _ components: (year: Int, month: Int, day: Int, hour: Int, minute: Int),
        stationIATA: String,
        stationTimeZones: [String: String],
        dutyID: String,
        flightNumber: String,
        field: String,
        issues: inout [RosterImportIssue]
    ) throws -> RosterLocalDateTime {
        guard let identifier = stationTimeZones[stationIATA] else {
            issues.append(
                RosterImportIssue(
                    code: .unresolvedStationTimeZone,
                    dutyID: dutyID,
                    flightNumber: flightNumber,
                    stationIATA: stationIATA
                )
            )
            return RosterLocalDateTime(
                year: components.year,
                month: components.month,
                day: components.day,
                hour: components.hour,
                minute: components.minute,
                timeZoneIdentifier: nil,
                instant: nil
            )
        }

        guard let timeZone = TimeZone(identifier: identifier),
              let instant = resolve(
                year: components.year,
                month: components.month,
                day: components.day,
                hour: components.hour,
                minute: components.minute,
                in: timeZone
              ) else {
            throw TAPRosterParserError.invalidFlight(
                dutyID: dutyID,
                flightNumber: flightNumber,
                field: field
            )
        }

        return RosterLocalDateTime(
            year: components.year,
            month: components.month,
            day: components.day,
            hour: components.hour,
            minute: components.minute,
            timeZoneIdentifier: identifier,
            instant: instant
        )
    }

    private static func resolve(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        in timeZone: TimeZone
    ) -> Date? {
        guard let utc = TimeZone(secondsFromGMT: 0) else {
            return nil
        }
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.locale = Locale(identifier: "en_US_POSIX")
        utcCalendar.timeZone = utc
        let requested = DateComponents(
            timeZone: utc,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: 0
        )
        guard let localFieldsAsUTC = utcCalendar.date(from: requested) else {
            return nil
        }

        // A repeated wall-clock time has two valid offsets. Never choose one
        // silently, because that could move a flight and its routine by an hour.
        let probeOffsets = [-172_800, -86_400, 0, 86_400, 172_800]
        let possibleOffsets = Set(probeOffsets.map {
            timeZone.secondsFromGMT(
                for: localFieldsAsUTC.addingTimeInterval(TimeInterval($0))
            )
        })
        let candidates = Set(possibleOffsets.compactMap { offset -> Date? in
            let candidate = localFieldsAsUTC.addingTimeInterval(
                TimeInterval(-offset)
            )
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US_POSIX")
            calendar.timeZone = timeZone
            let actual = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: candidate
            )
            guard actual.year == year,
                  actual.month == month,
                  actual.day == day,
                  actual.hour == hour,
                  actual.minute == minute,
                  actual.second == 0 else {
                return nil
            }
            return candidate
        })
        guard candidates.count == 1 else {
            return nil
        }
        return candidates.first
    }

    private static func splitFlightBlocks(_ description: String) -> [[String]] {
        let lines = description
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let starts = lines.indices.filter {
            folded(lines[$0]).hasPrefix("VOO ")
        }

        return starts.enumerated().map { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1] : lines.endIndex
            return Array(lines[start..<end])
        }
    }

    private static func parseActivityCode(_ description: String) -> String? {
        labeledValue("ACTIVIDADE", lines: description.components(separatedBy: "\n"))
    }

    private static func parseHotelCode(_ description: String) -> String? {
        guard let value = labeledValue(
            "HOTEL",
            lines: description.components(separatedBy: "\n")
        ) else {
            return nil
        }
        let code = value.uppercased().filter { $0.isLetter || $0.isNumber }
        return code.isEmpty ? nil : code
    }

    private static func parseAirport(
        _ value: String,
        dutyID: String,
        flightNumber: String,
        field: String
    ) throws -> (iata: String, name: String?) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.components(separatedBy: " - ")
        let iata = pieces.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        guard iata.utf8.count == 3,
              iata.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
              }) else {
            throw TAPRosterParserError.invalidFlight(
                dutyID: dutyID,
                flightNumber: flightNumber,
                field: field
            )
        }
        let name = pieces.count > 1
            ? normalizedOptional(pieces.dropFirst().joined(separator: " - "))
            : nil
        return (iata, name)
    }

    private static func parseAircraft(
        _ value: String?
    ) -> (registration: String?, name: String?) {
        guard let value = normalizedOptional(value) else {
            return (nil, nil)
        }
        let pieces = value.components(separatedBy: " - ")
        return (
            normalizedOptional(pieces.first)?.uppercased(),
            pieces.count > 1
                ? normalizedOptional(pieces.dropFirst().joined(separator: " - "))
                : nil
        )
    }

    private static func parseCrew(_ lines: [String]) -> [RosterCrewMember] {
        guard let crewStart = lines.firstIndex(where: {
            folded($0).hasPrefix("TRIPULACAO:")
        }) else {
            return []
        }

        return lines.dropFirst(crewStart + 1).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !folded(trimmed).hasPrefix("HOTEL:") else {
                return nil
            }
            guard let values = captures(
                pattern: "^([0-9]+\\.[0-9]+)\\s+([A-Za-z]{2,5})\\s+(.+)$",
                in: trimmed
            ), values.count == 3 else {
                return nil
            }

            let isDeadhead = folded(values[2]).hasSuffix("(DHC)")
            let name: String
            if isDeadhead,
               let range = values[2].range(
                   of: "(DHC)",
                   options: [.caseInsensitive, .backwards]
               ) {
                name = values[2][..<range.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                name = values[2].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !name.isEmpty else {
                return nil
            }

            return RosterCrewMember(
                employeeIdentifier: values[0],
                roleCode: values[1].uppercased(),
                name: name,
                isDeadhead: isDeadhead
            )
        }
    }

    private static func parseDouble(_ value: String?) -> Double? {
        guard let value = normalizedOptional(value) else {
            return nil
        }
        return Double(value.replacingOccurrences(of: ",", with: "."))
    }

    private static func parseCrewIdentifier(_ value: String?) -> String? {
        guard let value,
              let captures = captures(
                pattern: "Tripulante\\s+([0-9]+\\.[0-9]+)",
                in: value,
                caseInsensitive: true
              ), captures.count == 1 else {
            return nil
        }
        return captures[0]
    }

    private static func requiredLabeledValue(
        _ label: String,
        lines: [String],
        dutyID: String,
        flightNumber: String
    ) throws -> String {
        guard let value = normalizedOptional(labeledValue(label, lines: lines)) else {
            throw TAPRosterParserError.invalidFlight(
                dutyID: dutyID,
                flightNumber: flightNumber,
                field: label.lowercased()
            )
        }
        return value
    }

    private static func labeledValue(_ label: String, lines: [String]) -> String? {
        let normalizedLabel = folded(label)
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let candidate = folded(String(line[..<colon]))
            guard candidate == normalizedLabel else {
                continue
            }
            return String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func requiredText(
        _ name: String,
        event: ICalendarRawEvent,
        dutyID: String
    ) throws -> String {
        guard let value = normalizedOptional(event.firstText(name)) else {
            throw TAPRosterParserError.invalidEvent(dutyID: dutyID, field: name)
        }
        return value
    }

    private static func requiredProperty(
        _ name: String,
        event: ICalendarRawEvent,
        dutyID: String
    ) throws -> ICalendarRawProperty {
        guard let value = event.first(name) else {
            throw TAPRosterParserError.invalidEvent(dutyID: dutyID, field: name)
        }
        return value
    }

    private static func identifiesTAP(
        productIdentifier: String?,
        calendarName: String?
    ) -> Bool {
        let product = folded(productIdentifier ?? "")
        let name = folded(calendarName ?? "")
        return (product.contains("TAP") && product.contains("PORTAL DOV"))
            || name.contains("ESCALA TAP")
    }

    private static func normalizedTimeZones(
        _ values: [String: String]
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            guard let normalized = normalizedOptional(value) else {
                return nil
            }
            return (key.uppercased(), normalized)
        })
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func folded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .uppercased()
    }

    private static func isValidFlightNumber(_ value: String) -> Bool {
        guard (3...10).contains(value.utf8.count) else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        }
    }

    private static func captures(
        pattern: String,
        in value: String,
        caseInsensitive: Bool = false
    ) -> [String]? {
        let options: NSRegularExpression.Options = caseInsensitive
            ? [.caseInsensitive]
            : []
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: options
        ) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(
            in: value,
            options: [],
            range: range
        ) else {
            return nil
        }

        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else {
                return nil
            }
            return String(value[range])
        }
    }
}

private struct ICalendarRawProperty {
    let parameters: [String: String]
    let value: String
}

private struct ICalendarRawEvent {
    let properties: [String: [ICalendarRawProperty]]

    func first(_ name: String) -> ICalendarRawProperty? {
        properties[name.uppercased()]?.first
    }

    func firstRaw(_ name: String) -> String? {
        first(name)?.value
    }

    func firstText(_ name: String) -> String? {
        firstRaw(name).map(ICalendarSubsetParser.unescapeText)
    }
}

private struct ICalendarRawDocument {
    let properties: [String: [ICalendarRawProperty]]
    let events: [ICalendarRawEvent]

    func firstRaw(_ name: String) -> String? {
        properties[name.uppercased()]?.first?.value
    }

    func firstText(_ name: String) -> String? {
        firstRaw(name).map(ICalendarSubsetParser.unescapeText)
    }
}

private enum ICalendarSubsetParser {
    static func parse(_ text: String) throws -> ICalendarRawDocument {
        let lines = unfold(text)
        var stack: [String] = []
        var calendarProperties: [String: [ICalendarRawProperty]] = [:]
        var eventProperties: [String: [ICalendarRawProperty]]?
        var events: [ICalendarRawEvent] = []
        var sawCalendar = false

        for line in lines where !line.isEmpty {
            guard let content = parseContentLine(line) else {
                throw TAPRosterParserError.malformedCalendar
            }

            if content.name == "BEGIN" {
                let component = content.property.value.uppercased()
                if component == "VCALENDAR" {
                    guard stack.isEmpty, !sawCalendar else {
                        throw TAPRosterParserError.malformedCalendar
                    }
                    sawCalendar = true
                } else if component == "VEVENT" {
                    guard stack == ["VCALENDAR"], eventProperties == nil else {
                        throw TAPRosterParserError.malformedCalendar
                    }
                    eventProperties = [:]
                }
                stack.append(component)
                continue
            }

            if content.name == "END" {
                let component = content.property.value.uppercased()
                guard stack.last == component else {
                    throw TAPRosterParserError.malformedCalendar
                }
                if component == "VEVENT" {
                    guard let completedEventProperties = eventProperties else {
                        throw TAPRosterParserError.malformedCalendar
                    }
                    events.append(
                        ICalendarRawEvent(properties: completedEventProperties)
                    )
                    eventProperties = nil
                }
                stack.removeLast()
                continue
            }

            if stack == ["VCALENDAR"] {
                calendarProperties[content.name, default: []].append(content.property)
            } else if stack.last == "VEVENT" {
                eventProperties?[content.name, default: []].append(content.property)
            }
        }

        guard sawCalendar, stack.isEmpty, eventProperties == nil else {
            throw TAPRosterParserError.malformedCalendar
        }
        return ICalendarRawDocument(
            properties: calendarProperties,
            events: events
        )
    }

    static func unescapeText(_ value: String) -> String {
        var result = ""
        var index = value.startIndex

        while index < value.endIndex {
            let character = value[index]
            guard character == "\\" else {
                result.append(character)
                index = value.index(after: index)
                continue
            }

            let next = value.index(after: index)
            guard next < value.endIndex else {
                result.append(character)
                break
            }
            switch value[next] {
            case "n", "N":
                result.append("\n")
            case "\\":
                result.append("\\")
            case ",":
                result.append(",")
            case ";":
                result.append(";")
            default:
                result.append(value[next])
            }
            index = value.index(after: next)
        }

        return result
    }

    private static func unfold(_ text: String) -> [String] {
        let physicalLines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var lines: [String] = []

        for line in physicalLines {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += line.dropFirst()
            } else {
                lines.append(line)
            }
        }
        return lines
    }

    private static func parseContentLine(
        _ line: String
    ) -> (name: String, property: ICalendarRawProperty)? {
        guard let colon = line.firstIndex(of: ":") else {
            return nil
        }
        let header = line[..<colon]
        let value = String(line[line.index(after: colon)...])
        let parts = header.split(separator: ";", omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else {
            return nil
        }

        var parameters: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let equals = part.firstIndex(of: "=") else {
                return nil
            }
            let key = part[..<equals].uppercased()
            var parameterValue = String(part[part.index(after: equals)...])
            if parameterValue.hasPrefix("\"") && parameterValue.hasSuffix("\"") {
                parameterValue.removeFirst()
                parameterValue.removeLast()
            }
            parameters[key] = parameterValue
        }

        return (
            String(first).uppercased(),
            ICalendarRawProperty(parameters: parameters, value: value)
        )
    }
}
