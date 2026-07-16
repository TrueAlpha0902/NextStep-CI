import Foundation
import NextStepAcademic
import SwiftUI

struct CourseListView: View {
    @EnvironmentObject private var academicModel: AcademicAppModel
    @Binding var selectedCourseID: CourseID?
    var onOpenCourse: ((CourseID) -> Void)? = nil
    @State private var showsNewCourse = false

    private var activeCourses: [Course] {
        sortedCourses(with: .active)
    }

    private var archivedCourses: [Course] {
        sortedCourses(with: .archived)
    }

    var body: some View {
        Group {
            if showsInitialProgress {
                ProgressView("Loading courses...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("courses.loading")
            } else if let failure = blockingFailure {
                unavailableState(message: failure.message)
            } else if academicModel.courses.isEmpty {
                emptyState
            } else {
                courseList
            }
        }
        .navigationTitle("Courses")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsNewCourse = true
                } label: {
                    Label("New course", systemImage: "plus")
                }
                .disabled(!canCreateCourse)
                .accessibilityIdentifier("courses.add")
            }
        }
        .sheet(isPresented: $showsNewCourse) {
            NewCourseSheet()
                .environmentObject(academicModel)
        }
        .onChange(of: academicModel.courses.map(\.id)) { _, courseIDs in
            guard let selectedCourseID, !courseIDs.contains(selectedCourseID) else {
                return
            }
            self.selectedCourseID = nil
        }
        .overlay {
            if showsOperationProgress {
                ProgressView()
                    .controlSize(.large)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Updating courses")
                    .accessibilityIdentifier("courses.updating")
            }
        }
    }

    private var courseList: some View {
        List(selection: $selectedCourseID) {
            if let failure = nonblockingFailure {
                Section {
                    CourseWorkspaceFailureRow(failure: failure) {
                        Task { await academicModel.retry() }
                    }
                }
            }

            if !activeCourses.isEmpty {
                Section("Active") {
                    ForEach(activeCourses) { course in
                        courseRow(course)
                    }
                }
            }

            if !archivedCourses.isEmpty {
                Section("Archived") {
                    ForEach(archivedCourses) { course in
                        courseRow(course)
                    }
                }
            }
        }
        .accessibilityIdentifier("courses.list")
    }

    @ViewBuilder
    private func courseRow(_ course: Course) -> some View {
        if let onOpenCourse {
            Button {
                selectedCourseID = course.id
                onOpenCourse(course.id)
            } label: {
                CourseListRow(course: course)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            CourseListRow(course: course)
                .tag(course.id)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No courses", systemImage: "books.vertical")
        } description: {
            Text("Create a course to organize its class sessions and notes.")
        } actions: {
            Button {
                showsNewCourse = true
            } label: {
                Label("New course", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCreateCourse)
        }
        .accessibilityIdentifier("courses.empty")
    }

    private func unavailableState(message: String) -> some View {
        ContentUnavailableView {
            Label("Courses unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") {
                Task { await academicModel.retry() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("courses.retry")
        }
        .accessibilityIdentifier("courses.unavailable")
    }

    private var showsInitialProgress: Bool {
        guard academicModel.courses.isEmpty else { return false }
        return switch academicModel.availability {
        case .idle, .loading:
            true
        case .ready, .saving, .changingLibraryRoot, .unavailable:
            false
        }
    }

    private var showsOperationProgress: Bool {
        switch academicModel.availability {
        case .saving, .changingLibraryRoot:
            true
        case .idle, .loading, .ready, .unavailable:
            false
        }
    }

    private var canCreateCourse: Bool {
        if case .ready = academicModel.availability {
            return true
        }
        return false
    }

    private var blockingFailure: AcademicWorkspaceFailure? {
        guard academicModel.courses.isEmpty,
              case let .unavailable(failure) = academicModel.availability else {
            return nil
        }
        return failure
    }

    private var nonblockingFailure: AcademicWorkspaceFailure? {
        guard !academicModel.courses.isEmpty,
              case let .unavailable(failure) = academicModel.availability else {
            return nil
        }
        return failure
    }

    private func sortedCourses(with status: CourseStatus) -> [Course] {
        academicModel.courses
            .filter { $0.status == status }
            .sorted(by: CourseListOrdering.precedes)
    }
}

enum CourseListOrdering {
    static func precedes(_ lhs: Course, _ rhs: Course) -> Bool {
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        if lhs.code != rhs.code {
            return (lhs.code ?? "") < (rhs.code ?? "")
        }
        return lhs.id < rhs.id
    }
}

private struct CourseListRow: View {
    let course: Course

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(course.name)
                    .font(.headline)

                if !metadata.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            ForEach(metadata.indices, id: \.self) { index in
                                if index > metadata.startIndex {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 3))
                                        .accessibilityHidden(true)
                                }
                                Text(metadata[index])
                                    .lineLimit(1)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(metadata.indices, id: \.self) { index in
                                Text(metadata[index])
                                    .lineLimit(1)
                            }
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if course.status == .archived {
                Text("Archived")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("course.\(course.id.description)")
    }

    private var metadata: [String] {
        [course.code, course.term, course.instructor].compactMap { $0 }
    }
}

private struct CourseWorkspaceFailureRow: View {
    let failure: AcademicWorkspaceFailure
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Courses need attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(failure.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("courses.failure")
    }
}
