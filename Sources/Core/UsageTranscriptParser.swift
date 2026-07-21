import Foundation

struct UsageTranscriptParser: Sendable {
    enum ParseError: Error, Equatable {
        case incompleteUsageScreen
        case invalidPercentage
        case invalidResetTime
        case unknownTimeZone(String)
    }

    private enum Constants {
        static let sessionWindow: TimeInterval = 5 * 60 * 60
        static let weeklyWindow: TimeInterval = 7 * 24 * 60 * 60
        static let resetTolerance: TimeInterval = 5 * 60
        static let sessionHeading = "Current session"
        static let weeklyHeading = "Current week (all models)"
        static let fableHeading = "Current week (Fable)"
        static let followingHeading = "What's contributing"
    }

    func parse(_ transcript: String, now: Date = .now) throws -> UsageReport {
        let text = TerminalTranscript.plainText(from: transcript)
        let candidates = completeSections(in: text)
        guard !candidates.isEmpty else { throw ParseError.incompleteUsageScreen }

        var mostRecentError: Error?
        for sections in candidates.reversed() {
            do {
                return try parse(sections, now: now)
            } catch {
                if mostRecentError == nil {
                    mostRecentError = error
                }
            }
        }
        throw mostRecentError ?? ParseError.incompleteUsageScreen
    }

    private func parse(_ sections: Sections, now: Date) throws -> UsageReport {
        let sessionUsed = try usedPercent(in: sections.session)
        let allModelsUsed = try usedPercent(in: sections.allModels)
        let fableUsed = try usedPercent(in: sections.fable)
        let sessionReset = try sessionResetDate(in: sections.session, now: now)
        let weeklyReset = try weeklyResetDate(in: sections.allModels, now: now)
        let fableReset = try weeklyResetDate(in: sections.fable, now: now)
        try validate(reset: sessionReset, at: now, windowDuration: Constants.sessionWindow)
        try validate(reset: weeklyReset, at: now, windowDuration: Constants.weeklyWindow)
        try validate(reset: fableReset, at: now, windowDuration: Constants.weeklyWindow)

        guard
            let session = UsageSnapshot(
                usedPercent: sessionUsed,
                windowDuration: Constants.sessionWindow,
                resetsAt: sessionReset
            ),
            let allModels = UsageSnapshot(
                usedPercent: allModelsUsed,
                windowDuration: Constants.weeklyWindow,
                resetsAt: weeklyReset
            ),
            let fable = UsageSnapshot(
                usedPercent: fableUsed,
                windowDuration: Constants.weeklyWindow,
                resetsAt: fableReset
            )
        else {
            throw ParseError.invalidPercentage
        }

        return UsageReport(session: session, allModels: allModels, fable: fable)
    }

    private func completeSections(in text: String) -> [Sections] {
        let sessionStarts = text.ranges(of: Constants.sessionHeading)
        var sections: [Sections] = []

        for sessionStart in sessionStarts {
            let afterSessionHeading = text[sessionStart.upperBound...]
            guard let weeklyHeading = afterSessionHeading.range(of: Constants.weeklyHeading) else {
                continue
            }

            let afterWeeklyHeading = text[weeklyHeading.upperBound...]
            guard let fableHeading = afterWeeklyHeading.range(of: Constants.fableHeading) else {
                continue
            }

            let afterFableHeading = text[fableHeading.upperBound...]
            let fableEnd =
                afterFableHeading.range(of: Constants.followingHeading)?.lowerBound
                ?? afterFableHeading.endIndex

            sections.append(
                Sections(
                    session: String(afterSessionHeading[..<weeklyHeading.lowerBound]),
                    allModels: String(afterWeeklyHeading[..<fableHeading.lowerBound]),
                    fable: String(afterFableHeading[..<fableEnd])
                ))
        }
        return sections
    }

    private func usedPercent(in section: String) throws -> Int {
        guard
            let rawValue = captures(#"(\d{1,3})%\s*used"#, in: section).first,
            let value = Int(rawValue),
            (0...100).contains(value)
        else {
            throw ParseError.invalidPercentage
        }
        return value
    }

    private func sessionResetDate(in section: String, now: Date) throws -> Date {
        let values = captures(
            #"Resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)"#,
            in: section
        )
        guard values.count == 4 else { throw ParseError.invalidResetTime }

        let time = try clockTime(hour: values[0], minute: values[1], meridiem: values[2])
        let timeZone = try timeZone(named: values[3])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.timeZone = timeZone
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0

        guard var reset = validatedDate(from: components, using: calendar) else {
            throw ParseError.invalidResetTime
        }
        if reset <= now {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: reset) else {
                throw ParseError.invalidResetTime
            }
            reset = nextDay
        }
        return reset
    }

    private func weeklyResetDate(in section: String, now: Date) throws -> Date {
        let values = captures(
            #"Resets\s+([A-Z][a-z]{2})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)"#,
            in: section
        )
        guard values.count == 6 else { throw ParseError.invalidResetTime }

        let months = [
            "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
            "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
        ]
        guard
            let month = months[values[0].lowercased()],
            let day = Int(values[1]),
            (1...31).contains(day)
        else {
            throw ParseError.invalidResetTime
        }

        let time = try clockTime(hour: values[2], minute: values[3], meridiem: values[4])
        let timeZone = try timeZone(named: values[5])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = calendar.component(.year, from: now)
        components.month = month
        components.day = day
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0

        guard var reset = validatedDate(from: components, using: calendar) else {
            throw ParseError.invalidResetTime
        }
        if reset <= now {
            components.year = (components.year ?? 0) + 1
            guard let nextYear = validatedDate(from: components, using: calendar) else {
                throw ParseError.invalidResetTime
            }
            reset = nextYear
        }
        return reset
    }

    private func clockTime(hour: String, minute: String, meridiem: String) throws -> (hour: Int, minute: Int) {
        guard
            let rawHour = Int(hour),
            (1...12).contains(rawHour),
            let minute = Int(minute.isEmpty ? "0" : minute),
            (0...59).contains(minute)
        else {
            throw ParseError.invalidResetTime
        }

        let hour = rawHour % 12 + (meridiem.lowercased() == "pm" ? 12 : 0)
        return (hour, minute)
    }

    private func timeZone(named name: String) throws -> TimeZone {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let timeZone = TimeZone(identifier: trimmedName) ?? TimeZone(abbreviation: trimmedName.uppercased()) {
            return timeZone
        }
        throw ParseError.unknownTimeZone(trimmedName)
    }

    private func validatedDate(from components: DateComponents, using calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard
            actual.year == components.year,
            actual.month == components.month,
            actual.day == components.day,
            actual.hour == components.hour,
            actual.minute == components.minute,
            actual.second == components.second
        else {
            return nil
        }
        return date
    }

    private func validate(reset: Date, at now: Date, windowDuration: TimeInterval) throws {
        let remaining = reset.timeIntervalSince(now)
        guard remaining > 0, remaining <= windowDuration + Constants.resetTolerance else {
            throw ParseError.invalidResetTime
        }
    }

    private func captures(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: fullRange) else { return [] }

        return (1..<match.numberOfRanges).map { index in
            let matchRange = match.range(at: index)
            guard matchRange.location != NSNotFound, let range = Range(matchRange, in: text) else {
                return ""
            }
            return String(text[range])
        }
    }
}

private struct Sections {
    let session: String
    let allModels: String
    let fable: String
}

extension String {
    fileprivate func ranges(of searchTerm: String) -> [Range<String.Index>] {
        var matches: [Range<String.Index>] = []
        var searchRange = startIndex..<endIndex

        while let match = range(of: searchTerm, range: searchRange) {
            matches.append(match)
            searchRange = match.upperBound..<endIndex
        }
        return matches
    }
}
