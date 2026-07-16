import Foundation

public enum CourseStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case active
    case archived
}

public struct CourseScheduleRule: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: CourseScheduleRuleID
    public let courseID: CourseID
    public let isoWeekday: Int
    public let startMinute: Int
    public let durationMinutes: Int
    public let timeZoneIdentifier: String
    public let effectiveFrom: AcademicLocalDate?
    public let effectiveThrough: AcademicLocalDate?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: CourseScheduleRuleID = CourseScheduleRuleID(),
        courseID: CourseID,
        isoWeekday: Int,
        startMinute: Int,
        durationMinutes: Int,
        timeZoneIdentifier: String,
        effectiveFrom: AcademicLocalDate? = nil,
        effectiveThrough: AcademicLocalDate? = nil
    ) throws {
        try AcademicValidation.requireSchema(
            schemaVersion,
            current: Self.currentSchemaVersion,
            entity: "course schedule rule"
        )
        guard (1...7).contains(isoWeekday) else {
            throw AcademicDomainError.valueOutOfBounds(field: "schedule.isoWeekday")
        }
        guard (0..<1_440).contains(startMinute) else {
            throw AcademicDomainError.valueOutOfBounds(field: "schedule.startMinute")
        }
        guard (1...1_440).contains(durationMinutes) else {
            throw AcademicDomainError.valueOutOfBounds(field: "schedule.durationMinutes")
        }
        guard timeZoneIdentifier.utf8.count <= 255,
              TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw AcademicDomainError.invalidField("schedule.timeZoneIdentifier")
        }
        if let effectiveFrom, let effectiveThrough, effectiveFrom > effectiveThrough {
            throw AcademicDomainError.chronologyViolation(
                "A schedule rule cannot end before it starts."
            )
        }
        self.schemaVersion = schemaVersion
        self.id = id
        self.courseID = courseID
        self.isoWeekday = isoWeekday
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self.timeZoneIdentifier = timeZoneIdentifier
        self.effectiveFrom = effectiveFrom
        self.effectiveThrough = effectiveThrough
    }

    static func canonicalOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.isoWeekday != rhs.isoWeekday { return lhs.isoWeekday < rhs.isoWeekday }
        if lhs.startMinute != rhs.startMinute { return lhs.startMinute < rhs.startMinute }
        if lhs.durationMinutes != rhs.durationMinutes {
            return lhs.durationMinutes < rhs.durationMinutes
        }
        return lhs.id < rhs.id
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, courseID, isoWeekday, startMinute, durationMinutes
        case timeZoneIdentifier, effectiveFrom, effectiveThrough
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        do {
            try AcademicValidation.requireSchema(
                schemaVersion,
                current: Self.currentSchemaVersion,
                entity: "course schedule rule"
            )
            try self.init(
                schemaVersion: schemaVersion,
                id: try values.decode(CourseScheduleRuleID.self, forKey: .id),
                courseID: try values.decode(CourseID.self, forKey: .courseID),
                isoWeekday: try values.decode(Int.self, forKey: .isoWeekday),
                startMinute: try values.decode(Int.self, forKey: .startMinute),
                durationMinutes: try values.decode(Int.self, forKey: .durationMinutes),
                timeZoneIdentifier: try values.decode(String.self, forKey: .timeZoneIdentifier),
                effectiveFrom: try values.decodeIfPresent(
                    AcademicLocalDate.self,
                    forKey: .effectiveFrom
                ),
                effectiveThrough: try values.decodeIfPresent(
                    AcademicLocalDate.self,
                    forKey: .effectiveThrough
                )
            )
        } catch let error as AcademicDomainError {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: error.localizedDescription
            )
        }
    }
}

public struct Course: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: CourseID
    public let revision: Int64
    public let code: String?
    public let name: String
    public let term: String?
    public let instructor: String?
    public let timeZoneIdentifier: String
    public let scheduleRules: [CourseScheduleRule]
    public let status: CourseStatus
    public let createdAt: Date
    public let modifiedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: CourseID = CourseID(),
        revision: Int64 = 1,
        code: String? = nil,
        name: String,
        term: String? = nil,
        instructor: String? = nil,
        timeZoneIdentifier: String,
        scheduleRules: [CourseScheduleRule] = [],
        status: CourseStatus = .active,
        createdAt: Date = Date(),
        modifiedAt: Date? = nil
    ) throws {
        try AcademicValidation.requireSchema(
            schemaVersion,
            current: Self.currentSchemaVersion,
            entity: "course"
        )
        try AcademicValidation.requireRevision(revision)
        try AcademicValidation.requireText(
            name,
            field: "course.name",
            maximumCharacters: AcademicDomainLimits.maximumCourseNameCharacters,
            maximumUTF8Bytes: AcademicDomainLimits.maximumCourseNameUTF8Bytes,
            allowsNewlines: false
        )
        for (field, value) in [
            ("course.code", code),
            ("course.term", term),
            ("course.instructor", instructor),
        ] {
            try AcademicValidation.requireOptionalText(
                value,
                field: field,
                maximumCharacters: AcademicDomainLimits.maximumShortFieldCharacters,
                maximumUTF8Bytes: AcademicDomainLimits.maximumShortFieldUTF8Bytes,
                allowsNewlines: false
            )
        }
        guard timeZoneIdentifier.utf8.count <= 255,
              TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw AcademicDomainError.invalidField("course.timeZoneIdentifier")
        }
        guard scheduleRules.count <= AcademicDomainLimits.maximumScheduleRulesPerCourse else {
            throw AcademicDomainError.valueOutOfBounds(field: "course.scheduleRules")
        }
        try AcademicValidation.requireUnique(scheduleRules.map(\.id), entity: "schedule rule")
        guard scheduleRules.allSatisfy({ $0.courseID == id }) else {
            throw AcademicDomainError.relationshipMismatch(
                "Every schedule rule must belong to its containing course."
            )
        }
        let resolvedModifiedAt = modifiedAt ?? createdAt
        try AcademicValidation.requireChronology(
            earlier: createdAt,
            later: resolvedModifiedAt,
            detail: "A course cannot be modified before it is created."
        )
        self.schemaVersion = schemaVersion
        self.id = id
        self.revision = revision
        self.code = code
        self.name = name
        self.term = term
        self.instructor = instructor
        self.timeZoneIdentifier = timeZoneIdentifier
        self.scheduleRules = scheduleRules.sorted(by: CourseScheduleRule.canonicalOrder)
        self.status = status
        self.createdAt = createdAt
        self.modifiedAt = resolvedModifiedAt
    }

    public func replacingScheduleRules(
        _ rules: [CourseScheduleRule],
        at modifiedAt: Date
    ) throws -> Course {
        try Course(
            id: id,
            revision: AcademicValidation.nextRevision(after: revision),
            code: code,
            name: name,
            term: term,
            instructor: instructor,
            timeZoneIdentifier: timeZoneIdentifier,
            scheduleRules: rules,
            status: status,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, revision, code, name, term, instructor
        case timeZoneIdentifier, scheduleRules, status, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        do {
            try AcademicValidation.requireSchema(
                schemaVersion,
                current: Self.currentSchemaVersion,
                entity: "course"
            )
            let scheduleRules = try AcademicValidation.decodeBoundedArray(
                CourseScheduleRule.self,
                from: values,
                forKey: .scheduleRules,
                maximumCount: AcademicDomainLimits.maximumScheduleRulesPerCourse,
                field: "course.scheduleRules"
            )
            try self.init(
                schemaVersion: schemaVersion,
                id: try values.decode(CourseID.self, forKey: .id),
                revision: try values.decode(Int64.self, forKey: .revision),
                code: try values.decodeIfPresent(String.self, forKey: .code),
                name: try values.decode(String.self, forKey: .name),
                term: try values.decodeIfPresent(String.self, forKey: .term),
                instructor: try values.decodeIfPresent(String.self, forKey: .instructor),
                timeZoneIdentifier: try values.decode(
                    String.self,
                    forKey: .timeZoneIdentifier
                ),
                scheduleRules: scheduleRules,
                status: try values.decode(CourseStatus.self, forKey: .status),
                createdAt: try values.decode(Date.self, forKey: .createdAt),
                modifiedAt: try values.decode(Date.self, forKey: .modifiedAt)
            )
        } catch let error as AcademicDomainError {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: error.localizedDescription
            )
        }
    }
}
