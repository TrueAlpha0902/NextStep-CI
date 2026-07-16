import Foundation
import NextStepAcademic
import SwiftUI

struct CourseScheduleRuleDraft: Equatable, Identifiable {
    let id: CourseScheduleRuleID
    var isoWeekday: Int
    var startMinute: Int
    var durationMinutes: Int

    init(
        id: CourseScheduleRuleID = CourseScheduleRuleID(),
        isoWeekday: Int = 1,
        startMinute: Int = 9 * 60,
        durationMinutes: Int = 90
    ) {
        self.id = id
        self.isoWeekday = isoWeekday
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
    }

    init(rule: CourseScheduleRule) {
        self.init(
            id: rule.id,
            isoWeekday: rule.isoWeekday,
            startMinute: rule.startMinute,
            durationMinutes: rule.durationMinutes
        )
    }

    func makeRule(
        courseID: CourseID,
        timeZoneIdentifier: String
    ) throws -> CourseScheduleRule {
        try CourseScheduleRule(
            id: id,
            courseID: courseID,
            isoWeekday: isoWeekday,
            startMinute: startMinute,
            durationMinutes: durationMinutes,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }
}

enum CourseScheduleDraftFormatting {
    static func time(
        for startMinute: Int,
        timeZoneIdentifier: String
    ) -> Date {
        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: timeZone,
                year: 2001,
                month: 1,
                day: 1,
                hour: startMinute / 60,
                minute: startMinute % 60
            )
        ) ?? Date(timeIntervalSince1970: 0)
    }

    static func startMinute(
        from date: Date,
        timeZoneIdentifier: String
    ) -> Int {
        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return min(
            max((components.hour ?? 0) * 60 + (components.minute ?? 0), 0),
            1_439
        )
    }

    static func duration(
        minutes: Int,
        locale: Locale = .current
    ) -> String {
        let formatter = DateComponentsFormatter()
        formatter.calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            return calendar
        }()
        formatter.allowedUnits = minutes.isMultiple(of: 60) ? [.hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(minutes * 60)) ?? ""
    }
}

struct CourseScheduleRulesEditor: View {
    @Binding var rules: [CourseScheduleRuleDraft]
    let timeZoneIdentifier: String

    var body: some View {
        if rules.isEmpty {
            Label("No class times yet", systemImage: "calendar.badge.plus")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("courseSchedule.empty")
        } else {
            ForEach($rules) { $rule in
                CourseScheduleRuleEditorRow(
                    rule: $rule,
                    timeZoneIdentifier: timeZoneIdentifier,
                    onRemove: { remove(rule.id) }
                )
            }
        }

        Button {
            addRule()
        } label: {
            Label("Add class time", systemImage: "calendar.badge.plus")
        }
        .accessibilityIdentifier("courseSchedule.add")
    }

    private func addRule() {
        let weekday = rules.last.map { ($0.isoWeekday % 7) + 1 } ?? 1
        rules.append(CourseScheduleRuleDraft(isoWeekday: weekday))
    }

    private func remove(_ id: CourseScheduleRuleID) {
        rules.removeAll { $0.id == id }
    }
}

private struct CourseScheduleRuleEditorRow: View {
    @Binding var rule: CourseScheduleRuleDraft
    let timeZoneIdentifier: String
    let onRemove: () -> Void

    private var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }

    private var startTime: Binding<Date> {
        Binding(
            get: {
                CourseScheduleDraftFormatting.time(
                    for: rule.startMinute,
                    timeZoneIdentifier: timeZoneIdentifier
                )
            },
            set: {
                rule.startMinute = CourseScheduleDraftFormatting.startMinute(
                    from: $0,
                    timeZoneIdentifier: timeZoneIdentifier
                )
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Weekday", selection: $rule.isoWeekday) {
                ForEach(1...7, id: \.self) { weekday in
                    Text(CourseDetailFormatting.weekday(forISOWeekday: weekday))
                        .tag(weekday)
                }
            }
            .accessibilityIdentifier("courseSchedule.weekday.\(rule.id.description)")

            DatePicker(
                "Start time",
                selection: startTime,
                displayedComponents: .hourAndMinute
            )
            .environment(\.timeZone, timeZone)
            .accessibilityIdentifier("courseSchedule.start.\(rule.id.description)")

            Stepper(
                value: $rule.durationMinutes,
                in: 15...720,
                step: 15
            ) {
                LabeledContent(
                    "Duration",
                    value: CourseScheduleDraftFormatting.duration(
                        minutes: rule.durationMinutes
                    )
                )
            }
            .accessibilityIdentifier("courseSchedule.duration.\(rule.id.description)")

            Button(role: .destructive, action: onRemove) {
                Label("Remove class time", systemImage: "trash")
            }
            .accessibilityIdentifier("courseSchedule.remove.\(rule.id.description)")
        }
        .padding(.vertical, 4)
    }
}

struct CourseScheduleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var academicModel: AcademicAppModel
    let course: Course

    @State private var rules: [CourseScheduleRuleDraft]
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(course: Course) {
        self.course = course
        _rules = State(initialValue: course.scheduleRules.map(CourseScheduleRuleDraft.init))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Class schedule") {
                    CourseScheduleRulesEditor(
                        rules: $rules,
                        timeZoneIdentifier: course.timeZoneIdentifier
                    )
                }

                Section {
                    LabeledContent("Time zone", value: course.timeZoneIdentifier)
                } footer: {
                    Text("All class times use the course time zone.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("courseSchedule.error")

                        if academicModel.failure != nil {
                            Button("Reload course") {
                                reloadCourse()
                            }
                            .disabled(isWorking)
                            .accessibilityIdentifier("courseSchedule.reload")
                        }
                    }
                }
            }
            .accessibilityIdentifier("courseSchedule.form")
            .disabled(isWorking)
            .navigationTitle("Edit schedule")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave || isWorking)
                        .accessibilityIdentifier("courseSchedule.save")
                }
            }
            .overlay {
                if isWorking {
                    ProgressView("Saving schedule...")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("courseSchedule.saving")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var canSave: Bool {
        guard case .ready = academicModel.availability else { return false }
        return rules != course.scheduleRules.map(CourseScheduleRuleDraft.init)
    }

    private func save() {
        let domainRules: [CourseScheduleRule]
        do {
            domainRules = try rules.map {
                try $0.makeRule(
                    courseID: course.id,
                    timeZoneIdentifier: course.timeZoneIdentifier
                )
            }
        } catch {
            errorMessage = String(localized: "Check the class schedule and try again.")
            return
        }

        let timestamp = Date()
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            let didSave = await academicModel.apply(
                .replaceCourseSchedule(
                    id: course.id,
                    expectedRevision: course.revision,
                    rules: domainRules,
                    at: timestamp
                ),
                savedAt: timestamp
            )
            isWorking = false
            if didSave {
                dismiss()
            } else {
                errorMessage = academicModel.failure?.message
                    ?? String(localized: "The class schedule could not be saved. Reload and try again.")
            }
        }
    }

    private func reloadCourse() {
        isWorking = true
        Task { @MainActor in
            await academicModel.retry()
            isWorking = false
            if case .ready = academicModel.availability {
                dismiss()
            } else {
                errorMessage = academicModel.failure?.message
                    ?? String(localized: "Courses are still unavailable. Try again.")
            }
        }
    }
}
