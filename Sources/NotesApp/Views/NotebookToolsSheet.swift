import NotesServices
import SwiftUI

struct NotebookToolsSheet: View {
    private enum ToolAction: String, CaseIterable, Identifiable {
        case summarize
        case rewrite
        case outline
        case meetingNotes
        case quiz
        case ask
        case explain
        case calculate

        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .summarize: "Summarize"
            case .rewrite: "Clean up text"
            case .outline: "Create outline"
            case .meetingNotes: "Meeting notes"
            case .quiz: "Create quiz"
            case .ask: "Ask this page"
            case .explain: "Explain"
            case .calculate: "Calculator"
            }
        }

        var symbolName: String {
            switch self {
            case .summarize: "text.alignleft"
            case .rewrite: "text.badge.checkmark"
            case .outline: "list.bullet.indent"
            case .meetingNotes: "person.2"
            case .quiz: "rectangle.on.rectangle.angled"
            case .ask: "questionmark.bubble"
            case .explain: "lightbulb"
            case .calculate: "function"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    let notebookID: UUID
    let page: EditorPage

    @State private var sourceText = ""
    @State private var output = ""
    @State private var citations: [IntelligenceCitation] = []
    @State private var selectedAction: ToolAction = .summarize
    @State private var question = ""
    @State private var expression = ""
    @State private var isExtracting = false
    @State private var isRunning = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if supportsBackgroundTextExtraction {
                        Button {
                            Task { await extractPageText() }
                        } label: {
                            Label("Extract text from this page", systemImage: "text.viewfinder")
                        }
                        .disabled(isExtracting)

                        if isExtracting {
                            ProgressView("Reading page…")
                        }
                    }

                    TextEditor(text: $sourceText)
                        .frame(minHeight: 140)
                        .overlay(alignment: .topLeading) {
                            if sourceText.isEmpty {
                                Text("Extract PDF or image text, or paste text here.")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel("Source text")
                } header: {
                    Text("Source")
                } footer: {
                    if supportsHandwritingRecognition {
                        Text(verbatim: CurrentDevicePresentation.localized(
                            "PDF text and image OCR run on this iPad. Review handwriting below before using it as source text."
                        ))
                    } else {
                        Text(verbatim: CurrentDevicePresentation.localized(
                            "PDF text and image OCR run on this iPad."
                        ))
                    }
                }

                if supportsHandwritingRecognition {
                    HandwritingReviewSection(
                        notebookID: notebookID,
                        page: page,
                        sourceText: $sourceText
                    )
                }

                Section("Tool") {
                    Picker("Action", selection: $selectedAction) {
                        ForEach(ToolAction.allCases) { action in
                            Label(action.title, systemImage: action.symbolName)
                                .tag(action)
                        }
                    }

                    if selectedAction == .ask {
                        TextField("What do you want to know?", text: $question, axis: .vertical)
                    }
                    if selectedAction == .calculate {
                        TextField("Example: (12 + 8) / 4", text: $expression)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.numbersAndPunctuation)
                    }

                    Button {
                        Task { await runTool() }
                    } label: {
                        if isRunning {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Run on device", systemImage: "ipad.and.arrow.forward")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)
                }

                if !output.isEmpty {
                    Section("Result") {
                        Text(output)
                            .textSelection(.enabled)
                        if !citations.isEmpty {
                            DisclosureGroup("Source excerpts") {
                                ForEach(citations) { citation in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(citation.label)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        Text(citation.excerpt)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Label("The built-in tools are deterministic and work without an account or network.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Page tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func extractPageText() async {
        isExtracting = true
        defer { isExtracting = false }
        if let text = await appModel.extractText(notebookID: notebookID, page: page) {
            sourceText = text
        }
    }

    private var supportsBackgroundTextExtraction: Bool {
        switch page.background {
        case .paper: false
        case .pdf, .image: true
        }
    }

    private var supportsHandwritingRecognition: Bool {
        switch page.kind {
        case .notebook, .whiteboard, .importedDocument: true
        case .textDocument, .studySet: false
        }
    }

    private func runTool() async {
        isRunning = true
        defer { isRunning = false }
        let action: IntelligenceAction
        switch selectedAction {
        case .summarize: action = .summarize
        case .rewrite: action = .rewrite
        case .outline: action = .outline
        case .meetingNotes: action = .meetingNotes
        case .quiz: action = .quiz(questionCount: 5)
        case .ask: action = .ask(question: question)
        case .explain: action = .explain
        case .calculate: action = .calculate(expression: expression)
        }
        guard let result = await appModel.performIntelligence(action: action, text: sourceText) else { return }
        output = result.text
        citations = result.citations
    }
}
