import Foundation

public struct AcademicLocalDate: Codable, Hashable, Sendable, Comparable,
    CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        guard (1...9_999).contains(year),
              (1...12).contains(month),
              (1...31).contains(day) else {
            throw AcademicDomainError.valueOutOfBounds(field: "localDate")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else {
            throw AcademicDomainError.invalidField("localDate")
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day else {
            throw AcademicDomainError.invalidField("localDate")
        }
        self.year = year
        self.month = month
        self.day = day
    }

    public var isoWeekday: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        let foundationWeekday = calendar.component(
            .weekday,
            from: calendar.date(from: components)!
        )
        return ((foundationWeekday + 5) % 7) + 1
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private enum CodingKeys: String, CodingKey { case year, month, day }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let year = try values.decode(Int.self, forKey: .year)
        let month = try values.decode(Int.self, forKey: .month)
        let day = try values.decode(Int.self, forKey: .day)
        do {
            try self.init(year: year, month: month, day: day)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .day,
                in: values,
                debugDescription: error.localizedDescription
            )
        }
    }
}

public struct AcademicZonedInterval: Codable, Hashable, Sendable {
    public let localDate: AcademicLocalDate
    public let startMinute: Int
    public let durationMinutes: Int
    public let timeZoneIdentifier: String

    public init(
        localDate: AcademicLocalDate,
        startMinute: Int,
        durationMinutes: Int,
        timeZoneIdentifier: String
    ) throws {
        guard (0..<1_440).contains(startMinute) else {
            throw AcademicDomainError.valueOutOfBounds(field: "startMinute")
        }
        guard (1...1_440).contains(durationMinutes) else {
            throw AcademicDomainError.valueOutOfBounds(field: "durationMinutes")
        }
        guard timeZoneIdentifier.utf8.count <= 255,
              let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw AcademicDomainError.invalidField("timeZoneIdentifier")
        }
        _ = try Self.validatedStartDate(
            localDate: localDate,
            startMinute: startMinute,
            timeZone: timeZone
        )
        self.localDate = localDate
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var isoWeekday: Int { localDate.isoWeekday }

    public var startDate: Date {
        let timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return try! Self.validatedStartDate(
            localDate: localDate,
            startMinute: startMinute,
            timeZone: timeZone
        )
    }

    public var endDate: Date {
        startDate.addingTimeInterval(Double(durationMinutes) * 60)
    }

    private enum CodingKeys: String, CodingKey {
        case localDate, startMinute, durationMinutes, timeZoneIdentifier
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let localDate = try values.decode(AcademicLocalDate.self, forKey: .localDate)
        let startMinute = try values.decode(Int.self, forKey: .startMinute)
        let durationMinutes = try values.decode(Int.self, forKey: .durationMinutes)
        let timeZoneIdentifier = try values.decode(String.self, forKey: .timeZoneIdentifier)
        do {
            try self.init(
                localDate: localDate,
                startMinute: startMinute,
                durationMinutes: durationMinutes,
                timeZoneIdentifier: timeZoneIdentifier
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .timeZoneIdentifier,
                in: values,
                debugDescription: error.localizedDescription
            )
        }
    }

    private static func validatedStartDate(
        localDate: AcademicLocalDate,
        startMinute: Int,
        timeZone: TimeZone
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let hour = startMinute / 60
        let minute = startMinute % 60
        let components = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: localDate.year,
            month: localDate.month,
            day: localDate.day,
            hour: hour,
            minute: minute,
            second: 0
        )
        guard let date = calendar.date(from: components) else {
            throw AcademicDomainError.invalidField("zonedInterval.start")
        }
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard roundTrip.year == localDate.year,
              roundTrip.month == localDate.month,
              roundTrip.day == localDate.day,
              roundTrip.hour == hour,
              roundTrip.minute == minute,
              roundTrip.second == 0 else {
            throw AcademicDomainError.invalidField("zonedInterval.start")
        }
        return date
    }
}
