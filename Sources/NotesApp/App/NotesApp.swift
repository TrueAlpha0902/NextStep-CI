import SwiftUI
import NextStepDesignSystem

@main
@MainActor
struct NotesApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appModel: AppModel
    @StateObject private var academicModel: AcademicAppModel
    @State private var isNotesLibraryPresented = false

    init() {
        let composition = AppComposition.live()
        _appModel = StateObject(wrappedValue: composition.notes)
        _academicModel = StateObject(wrappedValue: composition.academic)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if launchArguments.contains("-nextstep-responsive-preview") {
                    NextStepResponsiveRootView()
                } else if (
                    launchArguments.contains("-ui-testing")
                        && !launchArguments.contains("-nextstep-beta-ui-test")
                ) || isNotesLibraryPresented {
                    LibraryView()
                        .safeAreaInset(edge: .top, spacing: 0) {
                            if !launchArguments.contains("-ui-testing") {
                                legacyLibraryReturnBar
                            }
                        }
                } else {
                    NextStepBetaRootView {
                        appModel.destination = .documents
                        isNotesLibraryPresented = true
                    }
                }
            }
            .environmentObject(appModel)
            .environmentObject(academicModel)
            .tint(.accentColor)
            .preferredColorScheme(
                launchArguments.contains("-nextstep-dark-preview")
                    ? .dark
                    : launchArguments.contains("-nextstep-light-preview")
                        ? .light
                        : nil
            )
            .onChange(of: scenePhase) { _, phase in
                guard phase != .active else { return }
                Task { _ = await appModel.flushAllPendingWrites() }
            }
        }
    }

    private var launchArguments: [String] {
        ProcessInfo.processInfo.arguments
    }

    private var legacyLibraryReturnBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                returnToTodayButton
                Spacer()
                Text("筆記是 NextStep 的來源")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            returnToTodayButton
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var returnToTodayButton: some View {
        Button {
            isNotesLibraryPresented = false
        } label: {
            Label("返回 Today", systemImage: "chevron.left")
                .font(.callout.weight(.semibold))
        }
        .accessibilityIdentifier("nextstep.notes.returnToday")
    }
}
