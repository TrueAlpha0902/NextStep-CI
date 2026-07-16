import Foundation
import NextStepAcademic
import SwiftUI

struct NewCourseDraft: Equatable {
    var name = ""
    var code = ""
    var term = ""
    var instructor = ""
    var scheduleRules: [CourseScheduleRuleDraft] = []

    var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func makeCourse(
        id: CourseID = CourseID(),
        timestamp: Date = Date(),
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) throws -> Course {
        try Course(
            id: id,
            code: Self.normalizedOptional(code),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            term: Self.normalizedOptional(term),
            instructor: Self.normalizedOptional(instructor),
            timeZoneIdentifier: timeZoneIdentifier,
            scheduleRules: try scheduleRules.map {
                try $0.makeRule(
                    courseID: id,
                    timeZoneIdentifier: timeZoneIdentifier
                )
            },
            status: .active,
            createdAt: timestamp,
            modifiedAt: timestamp
        )
    }

    private static func normalizedOptional(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

struct NewCourseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var academicModel: AcademicAppModel
    @FocusState private var focusedField: Field?
    @State private var draft = NewCourseDraft()
    @State private var isWorking = false
    @State private var errorMessage: String?

    private enum Field: Hashable {
        case name
        case code
        case term
        case instructor
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Course name", text: $draft.name)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .code }
                        .accessibilityIdentifier("newCourse.name")

                    TextField("Course code (optional)", text: $draft.code)
                        .focused($focusedField, equals: .code)
                        .textInputAutocapitalization(.characters)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .term }
                        .accessibilityIdentifier("newCourse.code")

                    TextField("Term (optional)", text: $draft.term)
                        .focused($focusedField, equals: .term)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .instructor }
                        .accessibilityIdentifier("newCourse.term")

                    TextField("Instructor (optional)", text: $draft.instructor)
                        .focused($focusedField, equals: .instructor)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .accessibilityIdentifier("newCourse.instructor")
                } header: {
                    Text("Course details")
                }

                Section("Class schedule") {
                    CourseScheduleRulesEditor(
                        rules: $draft.scheduleRules,
                        timeZoneIdentifier: TimeZone.current.identifier
                    )
                }

                if let errorMessage {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)

                            if academicModel.failure != nil {
                                Button("Retry") {
                                    retryWorkspace()
                                }
                                .buttonStyle(.bordered)
                                .disabled(isWorking)
                                .accessibilityIdentifier("newCourse.retry")
                            }
                        }
                        .accessibilityIdentifier("newCourse.error")
                    }
                }
            }
            .accessibilityIdentifier("newCourse.form")
            .disabled(isWorking)
            .navigationTitle("New course")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                        .accessibilityIdentifier("newCourse.cancel")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createCourse()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canCreate || isWorking)
                    .accessibilityIdentifier("newCourse.create")
                }
            }
            .overlay {
                if isWorking {
                    ProgressView("Updating courses")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("newCourse.creating")
                }
            }
            .task {
                guard focusedField == nil else { return }
                focusedField = .name
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func createCourse() {
        focusedField = nil
        errorMessage = nil

        let course: Course
        do {
            course = try draft.makeCourse()
        } catch {
            errorMessage = String(
                localized: "Check the course details and try again."
            )
            return
        }

        isWorking = true
        Task { @MainActor in
            let didCreate = await academicModel.apply(.addCourse(course))
            isWorking = false
            if didCreate {
                dismiss()
            } else {
                errorMessage = academicModel.failure?.message
                    ?? String(localized: "The course could not be saved. Try again.")
            }
        }
    }

    private var canCreate: Bool {
        guard draft.canSubmit else { return false }
        if case .ready = academicModel.availability {
            return true
        }
        return false
    }

    private func retryWorkspace() {
        isWorking = true
        Task { @MainActor in
            await academicModel.retry()
            isWorking = false
            if case .ready = academicModel.availability {
                errorMessage = nil
            } else {
                errorMessage = academicModel.failure?.message
                    ?? String(localized: "Courses are still unavailable. Try again.")
            }
        }
    }
}
