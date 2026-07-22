import Foundation

struct UsageTranscriptParser: Sendable {
    static let captureBeginMarker = "__CLAUDE_USAGE_MICRO_BEGIN__"
    static let captureEndMarker = "__CLAUDE_USAGE_MICRO_END__"

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
    }

    func parse(_ transcript: String, now: Date = .now) throws -> UsageReport {
        let plainText = TerminalTranscript.plainText(from: transcript)
        let text = boundedUsageText(in: plainText)
        let candidates = candidateSections(in: text)
        guard !candidates.isEmpty else { throw ParseError.incompleteUsageScreen }

        var bestReport: UsageReport?
        var bestWindowCount = 0
        var mostRecentError: Error?

        for sections in candidates {
            do {
                let report = try parse(sections, now: now)
                let windowCount = report.availableLimits.count
                if windowCount >= bestWindowCount {
                    bestReport = report
                    bestWindowCount = windowCount
                }
            } catch {
                mostRecentError = error
            }
        }

        guard let bestReport else {
            throw mostRecentError ?? ParseError.incompleteUsageScreen
        }
        return bestReport
    }

    private func parse(_ sections: [UsageLimit: String], now: Date) throws -> UsageReport {
        var snapshots: [UsageLimit: UsageSnapshot] = [:]
        var mostRecentError: Error?

        for limit in [UsageLimit.session, .allModels] {
            guard let section = sections[limit] else { continue }
            do {
                snapshots[limit] = try snapshot(for: limit, in: section, now: now)
            } catch {
                mostRecentError = error
            }
        }

        if let section = sections[.fable] {
            do {
                snapshots[.fable] = try snapshot(
                    for: .fable,
                    in: section,
                    fallbackReset: snapshots[.allModels]?.resetsAt,
                    now: now
                )
            } catch {
                mostRecentError = error
            }
        }

        guard
            let report = UsageReport(
                session: snapshots[.session],
                allModels: snapshots[.allModels],
                fable: snapshots[.fable]
            )
        else {
            throw mostRecentError ?? ParseError.incompleteUsageScreen
        }
        return report
    }

    private func snapshot(
        for limit: UsageLimit,
        in section: String,
        fallbackReset: Date? = nil,
        now: Date
    ) throws -> UsageSnapshot {
        let usedPercent = try usedPercent(in: section)
        let windowDuration: TimeInterval
        let resetsAt: Date

        switch limit {
        case .session:
            windowDuration = Constants.sessionWindow
            resetsAt = try sessionResetDate(in: section, now: now)
        case .allModels, .fable:
            windowDuration = Constants.weeklyWindow
            if containsReset(in: section) {
                resetsAt = try weeklyResetDate(in: section, now: now)
            } else if let fallbackReset {
                resetsAt = fallbackReset
            } else {
                throw ParseError.invalidResetTime
            }
        }

        try validate(reset: resetsAt, at: now, windowDuration: windowDuration)
        guard
            let snapshot = UsageSnapshot(
                usedPercent: usedPercent,
                windowDuration: windowDuration,
                resetsAt: resetsAt
            )
        else {
            throw ParseError.invalidPercentage
        }
        return snapshot
    }

    /// Splits terminal redraws into independent candidates before parsing fields. A partially
    /// rendered final redraw therefore cannot overwrite a more complete earlier reading.
    private func candidateSections(in text: String) -> [[UsageLimit: String]] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var groups: [HeadingGroup] = []
        var currentHeadings: [Heading] = []
        var seenLimits = Set<UsageLimit>()

        for (lineIndex, line) in lines.enumerated() {
            let isBoundary = isUsageBoundary(line)
            let limit = usageLimit(forHeading: line)
            let startsNewCandidate = isBoundary || limit.map(seenLimits.contains) == true
            if startsNewCandidate, !currentHeadings.isEmpty {
                groups.append(HeadingGroup(headings: currentHeadings, endLine: lineIndex))
                currentHeadings.removeAll(keepingCapacity: true)
                seenLimits.removeAll(keepingCapacity: true)
            }
            if isBoundary {
                continue
            }
            if let limit {
                currentHeadings.append(Heading(lineIndex: lineIndex, limit: limit))
                seenLimits.insert(limit)
            }
        }
        if !currentHeadings.isEmpty {
            groups.append(HeadingGroup(headings: currentHeadings, endLine: lines.count))
        }
        guard !groups.isEmpty else { return [] }

        return groups.compactMap { group in
            var sections: [UsageLimit: String] = [:]
            for (index, heading) in group.headings.enumerated() {
                let bodyStart = heading.lineIndex + 1
                let bodyEnd =
                    index + 1 < group.headings.count
                    ? group.headings[index + 1].lineIndex
                    : group.endLine
                guard bodyStart <= bodyEnd else { continue }
                sections[heading.limit] = lines[bodyStart..<bodyEnd].joined(separator: "\n")
            }
            return sections.isEmpty ? nil : sections
        }
    }

    private func boundedUsageText(in text: String) -> String {
        guard let begin = text.range(of: Self.captureBeginMarker, options: [.backwards]) else {
            return text
        }
        let payload = text[begin.upperBound...]
        guard let end = payload.range(of: Self.captureEndMarker) else {
            return String(payload)
        }
        return String(payload[..<end.lowerBound])
    }

    private func isUsageBoundary(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == Self.captureBeginMarker || trimmed == Self.captureEndMarker {
            return true
        }
        if ["$", ">", "❯"].contains(trimmed) {
            return true
        }

        let normalized = trimmed.lowercased().replacingOccurrences(of: "’", with: "'")
        return normalized.contains("what's contributing")
            || normalized.contains("/usage")
            || normalized.contains("/exit")
            || normalized.contains("context left")
            || normalized.contains("context remaining")
    }

    /// Uses semantic tokens instead of exact display strings. This tolerates punctuation,
    /// capitalization, and small wording changes while refusing to relabel an unknown model.
    private func usageLimit(forHeading heading: String) -> UsageLimit? {
        let tokens = heading.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let tokenSet = Set(tokens)
        let describesWeek = tokenSet.contains("week") || tokenSet.contains("weekly")

        if describesWeek, tokenSet.contains("fable") {
            return .fable
        }
        let allModelsHeadingTokens: Set<String> = [
            "all", "current", "limit", "model", "models", "week", "weekly",
        ]
        if describesWeek,
            tokenSet.contains("current") || tokenSet.contains("limit"),
            tokenSet.isSubset(of: allModelsHeadingTokens)
        {
            return .allModels
        }
        if tokenSet.contains("session"),
            tokenSet.contains("current") || tokenSet.contains("limit") || tokens.count == 1
        {
            return .session
        }
        return nil
    }

    private func usedPercent(in section: String) throws -> Int {
        let patterns: [(pattern: String, representsRemaining: Bool)] = [
            (#"(?<![\d.])(\d{1,3})(?![\d.])\s*%\s*(?:used|consumed)\b"#, false),
            (#"\b(?:used|consumed)\s*:?\s*(\d{1,3})(?![\d.])\s*%"#, false),
            (#"(?<![\d.])(\d{1,3})(?![\d.])\s*%\s*(?:remaining|left)\b"#, true),
            (#"\b(?:remaining|left)\s*:?\s*(\d{1,3})(?![\d.])\s*%"#, true),
        ]

        for pattern in patterns {
            guard let rawValue = captures(pattern.pattern, in: section).first else { continue }
            guard let value = Int(rawValue), (0...100).contains(value) else {
                throw ParseError.invalidPercentage
            }
            return pattern.representsRemaining ? 100 - value : value
        }
        throw ParseError.invalidPercentage
    }

    private func containsReset(in section: String) -> Bool {
        section.range(of: #"\bresets?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func sessionResetDate(in section: String, now: Date) throws -> Date {
        let values = captures(
            #"Resets?(?:\s+at)?\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)"#,
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
        if let reset = try calendarDateReset(in: section, now: now) {
            return reset
        }
        if let reset = try weekdayReset(in: section, now: now) {
            return reset
        }
        throw ParseError.invalidResetTime
    }

    private func calendarDateReset(in section: String, now: Date) throws -> Date? {
        let values = captures(
            #"Resets?(?:\s+on)?\s+([A-Za-z]+)\s+(\d{1,2})(?:st|nd|rd|th)?\s*,?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)"#,
            in: section
        )
        guard !values.isEmpty else { return nil }
        guard values.count == 6 else { throw ParseError.invalidResetTime }

        let months = [
            "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
            "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7,
            "july": 7, "aug": 8, "august": 8, "sep": 9, "sept": 9,
            "september": 9, "oct": 10, "october": 10, "nov": 11, "november": 11,
            "dec": 12, "december": 12,
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

    private func weekdayReset(in section: String, now: Date) throws -> Date? {
        let values = captures(
            #"Resets?(?:\s+on)?\s+([A-Za-z]+)\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)"#,
            in: section
        )
        guard !values.isEmpty else { return nil }
        guard values.count == 5 else { throw ParseError.invalidResetTime }

        let weekdays = [
            "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3,
            "tuesday": 3, "wed": 4, "wednesday": 4, "thu": 5, "thur": 5,
            "thurs": 5, "thursday": 5, "fri": 6, "friday": 6, "sat": 7,
            "saturday": 7,
        ]
        guard let targetWeekday = weekdays[values[0].lowercased()] else {
            throw ParseError.invalidResetTime
        }

        let time = try clockTime(hour: values[1], minute: values[2], meridiem: values[3])
        let timeZone = try timeZone(named: values[4])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let currentWeekday = calendar.component(.weekday, from: now)
        var daysAhead = (targetWeekday - currentWeekday + 7) % 7
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.timeZone = timeZone
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        guard var reset = validatedDate(from: components, using: calendar) else {
            throw ParseError.invalidResetTime
        }
        if daysAhead == 0, reset <= now {
            daysAhead = 7
        }
        guard let advancedReset = calendar.date(byAdding: .day, value: daysAhead, to: reset) else {
            throw ParseError.invalidResetTime
        }
        reset = advancedReset
        return reset
    }

    private func clockTime(
        hour: String,
        minute: String,
        meridiem: String
    ) throws -> (hour: Int, minute: Int) {
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
        if let timeZone =
            TimeZone(identifier: trimmedName) ?? TimeZone(abbreviation: trimmedName.uppercased())
        {
            return timeZone
        }
        throw ParseError.unknownTimeZone(trimmedName)
    }

    private func validatedDate(from components: DateComponents, using calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
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
        guard
            let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            )
        else {
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

private struct Heading {
    let lineIndex: Int
    let limit: UsageLimit
}

private struct HeadingGroup {
    let headings: [Heading]
    let endLine: Int
}
