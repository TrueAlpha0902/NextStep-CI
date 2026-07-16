import SwiftUI

public enum NextStepPreviewDestination: String, CaseIterable, Hashable, Sendable, Identifiable {
    case today
    case learning
    case papers
    case goals
    case workspace

    public var id: String { rawValue }

    public var compactTitle: String {
        switch self {
        case .today: "今天"
        case .learning: "引導"
        case .papers: "來源"
        case .goals: "目標"
        case .workspace: "工作"
        }
    }

    public var title: String {
        switch self {
        case .today: "Today · 今天"
        case .learning: "Guided Learning · 引導學習"
        case .papers: "Papers · 論文與來源"
        case .goals: "Goals · 目標與里程碑"
        case .workspace: "Workspaces · 研究、作品與求職"
        }
    }

    public var symbolName: String {
        switch self {
        case .today: "sun.max"
        case .learning: "book.pages"
        case .papers: "doc.text.magnifyingglass"
        case .goals: "target"
        case .workspace: "square.grid.2x2"
        }
    }
}

/// Integration-ready responsive entry point for the NextStep visual prototype.
/// Compact widths use independent NavigationStacks inside a bottom TabView;
/// regular iPad widths use a persistent NavigationSplitView sidebar.
public struct NextStepResponsiveRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var destination: NextStepPreviewDestination = .today
    @State private var showsGuidedLearningFromToday = false

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let layout = NextStepLayoutMode.resolve(
                width: proxy.size.width,
                isRegularWidth: horizontalSizeClass == .regular
            )
            if layout == .compact {
                compactRoot
            } else {
                regularRoot
            }
        }
        .tint(NextStepPalette.primaryAccent)
    }

    private var compactRoot: some View {
        TabView(selection: $destination) {
            NavigationStack {
                NextStepTodayScreen {
                    showsGuidedLearningFromToday = true
                }
                .navigationDestination(isPresented: $showsGuidedLearningFromToday) {
                    NextStepGuidedLearningScreen()
                }
            }
            .tabItem { destinationLabel(.today) }
            .tag(NextStepPreviewDestination.today)

            NavigationStack { NextStepGuidedLearningScreen() }
                .tabItem { destinationLabel(.learning) }
                .tag(NextStepPreviewDestination.learning)

            NavigationStack { NextStepPaperReaderScreen() }
                .tabItem { destinationLabel(.papers) }
                .tag(NextStepPreviewDestination.papers)

            NavigationStack { NextStepGoalMilestoneScreen() }
                .tabItem { destinationLabel(.goals) }
                .tag(NextStepPreviewDestination.goals)

            NavigationStack { NextStepWorkspaceScreen() }
                .tabItem { destinationLabel(.workspace) }
                .tag(NextStepPreviewDestination.workspace)
        }
        .accessibilityIdentifier("nextstep.compact.root")
    }

    private var regularRoot: some View {
        NavigationSplitView {
            List {
                ForEach(NextStepPreviewDestination.allCases) { item in
                    Button {
                        destination = item
                    } label: {
                        HStack {
                            Label(item.title, systemImage: item.symbolName)
                            Spacer()
                            if destination == item {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(NextStepPalette.primaryAccent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        destination == item
                            ? NextStepPalette.primaryAccent
                            : NextStepPalette.primaryText
                    )
                    .accessibilityIdentifier("nextstep.sidebar.\(item.rawValue)")
                    .accessibilityValue(destination == item ? "已選取" : "")
                }
            }
            .navigationTitle("NextStep")
            .navigationSplitViewColumnWidth(
                min: NextStepSize.sidebarMinimum,
                ideal: NextStepSize.sidebarIdeal,
                max: NextStepSize.sidebarMaximum
            )
        } detail: {
            NavigationStack {
                destinationView(destination)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .accessibilityIdentifier("nextstep.regular.root")
    }

    @ViewBuilder
    private func destinationView(_ destination: NextStepPreviewDestination) -> some View {
        switch destination {
        case .today:
            NextStepTodayScreen {
                self.destination = .learning
            }
        case .learning:
            NextStepGuidedLearningScreen()
        case .papers:
            NextStepPaperReaderScreen()
        case .goals:
            NextStepGoalMilestoneScreen()
        case .workspace:
            NextStepWorkspaceScreen()
        }
    }

    @ViewBuilder
    private func destinationLabel(_ destination: NextStepPreviewDestination) -> some View {
        Label(destination.compactTitle, systemImage: destination.symbolName)
    }
}

#Preview("Responsive Root · iPhone") {
    NextStepResponsiveRootView()
}

#Preview("Responsive Root · Dark") {
    NextStepResponsiveRootView()
        .preferredColorScheme(.dark)
}
