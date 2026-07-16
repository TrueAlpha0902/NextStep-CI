import Foundation
import NextStepAcademic
import SwiftUI

struct CourseDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var academicModel: AcademicAppModel
    let courseID: CourseID
    let onOpenSession: (SessionWorkspaceRoute) -> Void
    @State private var isEditingSchedule = false

    private var course: Course? {
        academicModel.courses.first { $0.id == courseID }
    }

    private var sessions: [CourseSession] {
        academicModel.workspace.sessions
            .filter { $0.courseID == courseID }
            .sorted(by: CourseDetailOrdering.sessionPrecedes)
    }

    private var pendingRecovery: (PendingSessionStart, AcademicWorkspaceFailure)? {
        guard case let .recoveryRequired(pending, failure) = academicModel.sessionStartState,
              pending.courseID == courseID else { return nil }
        return (pending, failure)
    }

    private var activeSession: CourseSession? {
        sessions.first { $0.status == .active }
    }

    private var activeRoute: SessionWorkspaceRoute? {
        guard let activeSession else { return nil }
        return route(for: activeSession)
    }

    private var availableActiveRoute: SessionWorkspaceRoute? {
        guard let activeRoute, noteIsAvailable(for: activeRoute) else { return nil }
        return activeRoute
    }

    var body: some View {
        Group {
            if let course {
                Form {
                    courseSection(course)
                    scheduleSection(course.scheduleRules)
                    if let pendingRecovery {
                        recoverySection(
                            pending: pendingRecovery.0,
                            failure: pendingRecovery.1,
                            course: course
                        )
                    }
                    sessionSection
                }
                .accessibilityIdentifier("course.detail")
            } else {
                ContentUnavailableView {
                    Label("Course not found", systemImage: "questionmark.folder")
                } description: {
                    Text("The course may have moved or been removed.")
                }
                .accessibilityIdentifier("courses.detail.empty")
            }
        }
        .navigationTitle(course?.name ?? String(localized: "Course"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let course, course.status == .active {
                    Button {
                        isEditingSchedule = true
                    } label: {
                        Label("Edit schedule", systemImage: "calendar.badge.plus")
                    }
                    .disabled(isWorkingOnThisCourse)
                    .accessibilityIdentifier("course.editSchedule")
                }

                if let course, course.status == .active {
                    Button {
                        if let availableActiveRoute {
                            onOpenSession(availableActiveRoute)
                        } else if activeSession == nil {
                            startSession(for: course)
                        }
                    } label: {
                        Label(
                            activeSession == nil
                                ? String(localized: "Start class")
                                : String(localized: "Resume class"),
                            systemImage: activeSession == nil ? "play.fill" : "arrow.right.circle.fill"
                        )
                    }
                    .disabled(!canStartOrResume)
                    .accessibilityIdentifier("course.startSession")
                }
            }
        }
        .sheet(isPresented: $isEditingSchedule) {
            if let course {
                CourseScheduleEditorSheet(course: course)
            }
        }
        .overlay {
            if isWorkingOnThisCourse {
                ProgressView("Preparing class note...")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("course.session.starting")
            }
        }
    }

    @ViewBuilder
    private func courseSection(_ course: Course) -> some View {
        Section("Course details") {
            LabeledContent("Name", value: course.name)
            if let code = course.code {
                LabeledContent("Course code", value: code)
            }
            if let term = course.term {
                LabeledContent("Term", value: term)
            }
            if let instructor = course.instructor {
                LabeledContent("Instructor", value: instructor)
            }
            LabeledContent("Time zone", value: course.timeZoneIdentifier)
            LabeledContent(
                "Status",
                value: course.status == .active
                    ? String(localized: "Active")
                    : String(localized: "Archived")
            )
        }
    }

    @ViewBuilder
    private func scheduleSection(_ rules: [CourseScheduleRule]) -> some View {
        Section("Class schedule") {
            if rules.isEmpty {
                Label("No class times yet", systemImage: "calendar.badge.plus")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rules) { rule in
                    LabeledContent {
                        Text(CourseDetailFormatting.time(for: rule))
                    } label: {
                        Text(
                            CourseDetailFormatting.weekday(
                                forISOWeekday: rule.isoWeekday
                            )
                        )
                    }
                    .accessibilityIdentifier("course.schedule.rule")
                }
            }
        }
    }

    @ViewBuilder
    private var sessionSection: some View {
        Section("Class sessions") {
            if sessions.isEmpty {
                Label("No class sessions yet", systemImage: "rectangle.stack")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessions) { session in
                    if let route = route(for: session), noteIsAvailable(for: route) {
                        Button {
                            onOpenSession(route)
                        } label: {
                            CourseSessionSummaryRow(session: session)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Open class note")
                    } else {
                        CourseSessionSummaryRow(session: session)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recoverySection(
        pending: PendingSessionStart,
        failure: AcademicWorkspaceFailure,
        course: Course
    ) -> some View {
        Section("Class note recovery") {
            Label("This session needs attention", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(failure.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                retrySessionStart(pending, for: course)
            } label: {
                Label("Retry preparing note", systemImage: "arrow.clockwise")
            }
            .disabled(isWorkingOnThisCourse)
            .accessibilityIdentifier("course.session.retry")

            if let route = pending.route, noteIsAvailable(for: route) {
                Button {
                    onOpenSession(route)
                } label: {
                    Label("Open saved note", systemImage: "doc.text")
                }
                .accessibilityIdentifier("course.session.openRecoveredNote")
            }
        }
        .accessibilityIdentifier("course.session.recovery")
    }

    private var canStartOrResume: Bool {
        guard !isWorkingOnThisCourse, pendingRecovery == nil else { return false }
        if activeSession != nil { return availableActiveRoute != nil }
        guard academicModel.sessionStartState == .idle else { return false }
        if case .ready = academicModel.availability { return true }
        return false
    }

    private var isWorkingOnThisCourse: Bool {
        guard case let .working(workingCourseID, _) = academicModel.sessionStartState else {
            return false
        }
        return workingCourseID == courseID
    }

    private func startSession(for course: Course) {
        Task { @MainActor in
            let startedAt = Date()
            let outcome = await academicModel.startSession(
                courseID: course.id,
                startedAt: startedAt,
                noteTitle: SessionNoteTitle.make(
                    courseName: course.name,
                    at: startedAt,
                    timeZoneIdentifier: course.timeZoneIdentifier
                )
            ) { @MainActor request in
                await appModel.ensureSessionTextNote(request)
            }
            if case let .started(route) = outcome {
                onOpenSession(route)
            }
        }
    }

    private func retrySessionStart(
        _ pending: PendingSessionStart,
        for course: Course
    ) {
        Task { @MainActor in
            let outcome = await academicModel.retryPendingSessionStart(
                noteTitle: SessionNoteTitle.make(
                    courseName: course.name,
                    at: pending.session.createdAt,
                    timeZoneIdentifier: course.timeZoneIdentifier
                )
            ) { @MainActor request in
                await appModel.ensureSessionTextNote(request)
            }
            if case let .started(route) = outcome {
                onOpenSession(route)
            }
        }
    }

    private func route(for session: CourseSession) -> SessionWorkspaceRoute? {
        guard let link = academicModel.workspace.sessionNoteLinks.first(where: {
            $0.sessionID == session.id && $0.isActive
        }), let initialPageID = link.initialPageID?.rawValue else { return nil }
        return SessionWorkspaceRoute(
            courseID: session.courseID,
            sessionID: session.id,
            notebookID: link.noteID.rawValue,
            initialPageID: initialPageID
        )
    }

    private func noteIsAvailable(for route: SessionWorkspaceRoute) -> Bool {
        appModel.notebooks.contains {
            $0.id == route.notebookID && $0.deletedAt == nil
        }
    }
}

enum SessionNoteTitle {
    static func make(
        courseName: String,
        at date: Date,
        timeZoneIdentifier: String,
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(courseName) — \(formatter.string(from: date))"
    }
}

enum CourseDetailOrdering {
    static func sessionPrecedes(_ lhs: CourseSession, _ rhs: CourseSession) -> Bool {
        let lhsDate = lhs.scheduledInterval?.startDate ?? lhs.actualStartedAt ?? lhs.createdAt
        let rhsDate = rhs.scheduledInterval?.startDate ?? rhs.actualStartedAt ?? rhs.createdAt
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        return lhs.id < rhs.id
    }
}

enum CourseDetailFormatting {
    static func weekday(forISOWeekday isoWeekday: Int, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar.weekdaySymbols[isoWeekday % 7]
    }

    static func time(for rule: CourseScheduleRule, locale: Locale = .current) -> String {
        let timeZone = TimeZone(identifier: rule.timeZoneIdentifier) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let components = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: 2001,
            month: 1,
            day: 1,
            hour: rule.startMinute / 60,
            minute: rule.startMinute % 60
        )
        guard let date = calendar.date(from: components) else {
            return ""
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct CourseSessionSummaryRow: View {
    let session: CourseSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.topic ?? String(localized: "Class session"))
                .font(.headline)

            HStack(spacing: 6) {
                Text(sessionDate, format: .dateTime.year().month().day().hour().minute())
                Image(systemName: "circle.fill")
                    .font(.system(size: 3))
                    .accessibilityHidden(true)
                Text(statusTitle)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("course.session.\(session.id.description)")
    }

    private var sessionDate: Date {
        session.scheduledInterval?.startDate ?? session.actualStartedAt ?? session.createdAt
    }

    private var statusTitle: String {
        switch session.status {
        case .planned:
            String(localized: "Planned")
        case .active:
            String(localized: "In progress")
        case .needsReview:
            String(localized: "Needs review")
        case .reviewed:
            String(localized: "Reviewed")
        case .cancelled:
            String(localized: "Cancelled")
        }
    }
}
