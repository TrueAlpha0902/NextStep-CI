import SwiftUI

/// A compact visual contract for the shared component states. Product screens
/// use the same enum, so unavailable, offline and uncertain states retain both
/// an icon and a text label instead of relying on color alone.
public struct NextStepComponentStateGallery: View {
    public init() {}

    public var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 156), spacing: NextStepSpacing.sm)],
                spacing: NextStepSpacing.sm
            ) {
                ForEach(NextStepComponentState.allCases) { state in
                    VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
                        NextStepStateBadge(state: state)
                        Text(state.rawValue)
                            .font(NextStepTypography.metadata)
                            .foregroundStyle(NextStepPalette.secondaryText)
                        Text(state.allowsInteraction ? "可互動" : "保留資訊但停止操作")
                            .font(NextStepTypography.supporting)
                            .foregroundStyle(NextStepPalette.primaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nextStepCard(state: state)
                }
            }
            .padding(NextStepSpacing.md)
        }
        .background(NextStepPalette.appBackground)
        .navigationTitle("Component States")
    }
}

#Preview("Component State Matrix") {
    NavigationStack { NextStepComponentStateGallery() }
}
