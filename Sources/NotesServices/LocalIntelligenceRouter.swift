import Foundation

/// A runtime adapter for an optional, user-installed language model. The app can ship without one;
/// attaching a runtime never changes the ownership or location of note data.
public protocol LocalLanguageModelRuntime: Sendable {
    var modelIdentifier: String { get async }
    func generate(for request: IntelligenceRequest) async throws -> String
}

public actor LocalIntelligenceRouter: IntelligenceProviding {
    public nonisolated let providerName = "Local intelligence router"

    private let fallback: ExtractiveIntelligenceProvider
    private var runtime: (any LocalLanguageModelRuntime)?

    public init(
        fallback: ExtractiveIntelligenceProvider = ExtractiveIntelligenceProvider(),
        runtime: (any LocalLanguageModelRuntime)? = nil
    ) {
        self.fallback = fallback
        self.runtime = runtime
    }

    public func attach(runtime: (any LocalLanguageModelRuntime)?) {
        self.runtime = runtime
    }

    public func perform(_ request: IntelligenceRequest) async throws -> IntelligenceResult {
        if Self.mustUseDeterministicEngine(for: request.action) || runtime == nil {
            return try await fallback.perform(request)
        }
        guard let runtime else { throw IntelligenceProviderError.generativeModelRequired }
        let text = try await runtime.generate(for: request)
        let modelIdentifier = await runtime.modelIdentifier
        return IntelligenceResult(
            text: text,
            citations: request.citations,
            providerName: modelIdentifier,
            isGenerative: true
        )
    }

    private static func mustUseDeterministicEngine(for action: IntelligenceAction) -> Bool {
        switch action {
        case .calculate:
            true
        case .summarize, .rewrite, .outline, .meetingNotes, .quiz, .ask, .explain, .translate:
            false
        }
    }
}
