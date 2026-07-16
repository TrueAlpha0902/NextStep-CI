import SwiftUI
import UIKit

public enum NextStepSpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 48
}

public enum NextStepRadius {
    public static let control: CGFloat = 8
    public static let card: CGFloat = 12
    public static let sheet: CGFloat = 18
}

public enum NextStepSize {
    public static let minimumTapTarget: CGFloat = 44
    public static let compactContentMaximum: CGFloat = 680
    public static let readingColumnMaximum: CGFloat = 720
    public static let sidebarMinimum: CGFloat = 224
    public static let sidebarIdeal: CGFloat = 256
    public static let sidebarMaximum: CGFloat = 288
    public static let inspectorWidth: CGFloat = 320
}

public enum NextStepTypography {
    public static var display: Font {
        .system(.largeTitle, design: .rounded, weight: .semibold)
    }

    public static var pageTitle: Font {
        .system(.title, design: .rounded, weight: .semibold)
    }

    public static var sectionTitle: Font {
        .system(.title3, design: .rounded, weight: .semibold)
    }

    public static var body: Font {
        .system(.body, design: .default, weight: .regular)
    }

    public static var supporting: Font {
        .system(.subheadline, design: .default, weight: .regular)
    }

    public static var citation: Font {
        .system(.subheadline, design: .serif, weight: .regular)
    }

    public static var metadata: Font {
        .system(.caption, design: .monospaced, weight: .medium)
    }

    public static var annotation: Font {
        .system(.caption, design: .rounded, weight: .medium)
    }

    public static var button: Font {
        .system(.body, design: .rounded, weight: .semibold)
    }
}

public enum NextStepPalette {
    public static var appBackground: Color {
        adaptiveColor(light: 0xF7F5EF, dark: 0x171816)
    }

    public static var surface: Color {
        adaptiveColor(light: 0xFEFDF9, dark: 0x1E201D)
    }

    public static var elevatedSurface: Color {
        adaptiveColor(light: 0xFFFFFF, dark: 0x282A26)
    }

    public static var primaryText: Color {
        adaptiveColor(light: 0x22231F, dark: 0xF1F0EA)
    }

    public static var secondaryText: Color {
        adaptiveColor(light: 0x62655E, dark: 0xB8BAB3)
    }

    public static var divider: Color {
        adaptiveColor(light: 0xD8D6CF, dark: 0x3D403A)
    }

    public static var primaryAccent: Color {
        adaptiveColor(light: 0x2E5E63, dark: 0x8DB8BA)
    }

    public static var success: Color {
        adaptiveColor(light: 0x2F6B4F, dark: 0x7EC59F)
    }

    public static var warning: Color {
        adaptiveColor(light: 0x8A5A22, dark: 0xE4B66F)
    }

    public static var error: Color {
        adaptiveColor(light: 0x9A3F3F, dark: 0xEF9991)
    }

    public static var aiGenerated: Color {
        adaptiveColor(light: 0x67528D, dark: 0xB9A4E0)
    }

    public static var userConfirmed: Color {
        adaptiveColor(light: 0x2A657A, dark: 0x80C3DD)
    }

    public static var sourceVerified: Color {
        adaptiveColor(light: 0x356D54, dark: 0x81C6A0)
    }

    public static var sourceUnverified: Color {
        adaptiveColor(light: 0x875A30, dark: 0xE2B07A)
    }

    public static var highlightConclusion: Color {
        adaptiveColor(light: 0xF3D96B, dark: 0x8B7526)
    }

    public static var highlightDefinition: Color {
        adaptiveColor(light: 0x9CC7DF, dark: 0x315F7A)
    }

    public static var highlightApplication: Color {
        adaptiveColor(light: 0xA9D4AF, dark: 0x3C7049)
    }

    public static var highlightRisk: Color {
        adaptiveColor(light: 0xE9B47D, dark: 0x8C552E)
    }

    public static var highlightConnection: Color {
        adaptiveColor(light: 0xC9B1DD, dark: 0x674A7E)
    }

    private static func adaptiveColor(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            color(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    private static func color(hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

public enum NextStepHighlightKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case conclusion
    case definition
    case application
    case risk
    case connection

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .conclusion: "核心結論"
        case .definition: "定義、公式或數據"
        case .application: "案例與應用"
        case .risk: "限制、風險或爭議"
        case .connection: "既有知識與目標連結"
        }
    }

    public var symbolName: String {
        switch self {
        case .conclusion: "star.fill"
        case .definition: "function"
        case .application: "arrow.triangle.branch"
        case .risk: "exclamationmark.triangle.fill"
        case .connection: "link"
        }
    }

    public var color: Color {
        switch self {
        case .conclusion: NextStepPalette.highlightConclusion
        case .definition: NextStepPalette.highlightDefinition
        case .application: NextStepPalette.highlightApplication
        case .risk: NextStepPalette.highlightRisk
        case .connection: NextStepPalette.highlightConnection
        }
    }
}

public enum NextStepComponentState: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case standard = "default"
    case pressed
    case selected
    case disabled
    case loading
    case completed
    case overdue
    case error
    case offline
    case aiUncertain
    case sourceUnavailable

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "可執行"
        case .pressed: "已按下"
        case .selected: "已選取"
        case .disabled: "暫不可使用"
        case .loading: "載入中"
        case .completed: "已完成"
        case .overdue: "已逾期"
        case .error: "發生錯誤"
        case .offline: "離線可用"
        case .aiUncertain: "AI 信心不足"
        case .sourceUnavailable: "來源目前無法存取"
        }
    }

    public var symbolName: String {
        switch self {
        case .standard: "circle"
        case .pressed: "hand.tap.fill"
        case .selected: "checkmark.circle.fill"
        case .disabled: "nosign"
        case .loading: "arrow.clockwise"
        case .completed: "checkmark.seal.fill"
        case .overdue: "clock.badge.exclamationmark.fill"
        case .error: "exclamationmark.octagon.fill"
        case .offline: "wifi.slash"
        case .aiUncertain: "sparkles"
        case .sourceUnavailable: "link.badge.plus"
        }
    }

    public var foregroundColor: Color {
        switch self {
        case .completed: NextStepPalette.success
        case .overdue, .sourceUnavailable: NextStepPalette.warning
        case .error: NextStepPalette.error
        case .aiUncertain: NextStepPalette.aiGenerated
        case .disabled: NextStepPalette.secondaryText.opacity(0.6)
        case .selected, .pressed: NextStepPalette.primaryAccent
        case .standard, .loading, .offline: NextStepPalette.secondaryText
        }
    }

    public var backgroundColor: Color {
        switch self {
        case .pressed, .selected:
            NextStepPalette.primaryAccent.opacity(0.08)
        case .completed:
            NextStepPalette.success.opacity(0.07)
        case .overdue, .sourceUnavailable:
            NextStepPalette.warning.opacity(0.08)
        case .error:
            NextStepPalette.error.opacity(0.07)
        case .aiUncertain:
            NextStepPalette.aiGenerated.opacity(0.08)
        case .offline:
            NextStepPalette.secondaryText.opacity(0.06)
        case .standard, .disabled, .loading:
            NextStepPalette.surface
        }
    }

    public var borderColor: Color {
        switch self {
        case .standard, .disabled, .loading, .offline:
            NextStepPalette.divider
        default:
            foregroundColor.opacity(0.7)
        }
    }

    public var allowsInteraction: Bool {
        switch self {
        case .disabled, .loading, .error, .sourceUnavailable:
            false
        default:
            true
        }
    }
}

public enum NextStepLayoutMode: String, Codable, Hashable, Sendable {
    case compact
    case balanced
    case expansive

    public static func resolve(width: CGFloat, isRegularWidth: Bool) -> Self {
        guard isRegularWidth else { return .compact }
        if width >= 1_024 { return .expansive }
        if width >= 680 { return .balanced }
        return .compact
    }

    public var horizontalPadding: CGFloat {
        switch self {
        case .compact: NextStepSpacing.md
        case .balanced: NextStepSpacing.lg
        case .expansive: NextStepSpacing.xl
        }
    }
}

public struct NextStepAdaptiveView<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let content: (NextStepLayoutMode) -> Content

    public init(@ViewBuilder content: @escaping (NextStepLayoutMode) -> Content) {
        self.content = content
    }

    public var body: some View {
        GeometryReader { proxy in
            let mode = NextStepLayoutMode.resolve(
                width: proxy.size.width,
                isRegularWidth: horizontalSizeClass == .regular
            )
            content(mode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

public struct NextStepCardModifier: ViewModifier {
    private let state: NextStepComponentState

    public init(state: NextStepComponentState = .standard) {
        self.state = state
    }

    public func body(content: Content) -> some View {
        content
            .padding(NextStepSpacing.md)
            .background(state.backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: NextStepRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: NextStepRadius.card, style: .continuous)
                    .stroke(state.borderColor, lineWidth: 1)
            }
            .opacity(state == .disabled ? 0.58 : 1)
            .scaleEffect(state == .pressed ? 0.995 : 1)
    }
}

public extension View {
    func nextStepCard(state: NextStepComponentState = .standard) -> some View {
        modifier(NextStepCardModifier(state: state))
    }
}
