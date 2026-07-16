import Foundation
import NextStepAcademic
import NotesCore
import SwiftUI
import UIKit

struct TextDocumentPageEditor: View {
    @Binding var document: TextDocument
    let saveState: InkSaveState
    let onDocumentChanged: (TextDocument) -> Void
    let onRetry: () -> Void
    let capturePresentation: TextDocumentCapturePresentation?
    let captureKindsByBlockID: [TextBlockID: Set<CaptureKind>]
    let onCapture: ((TextBlockID, CaptureKind) -> Void)?
    let onRetryCapture: (() -> Void)?
    let onCancelCapture: (() -> Void)?

    @FocusState private var focusedBlockID: TextBlockID?
    @State private var pendingDividerBlockID: TextBlockID?
    @State private var captureTargetBlockID: TextBlockID?
    @State private var isDispatchingCaptureAction = false

    init(
        document: Binding<TextDocument>,
        saveState: InkSaveState,
        onDocumentChanged: @escaping (TextDocument) -> Void,
        onRetry: @escaping () -> Void,
        capturePresentation: TextDocumentCapturePresentation? = nil,
        captureKindsByBlockID: [TextBlockID: Set<CaptureKind>] = [:],
        onCapture: ((TextBlockID, CaptureKind) -> Void)? = nil,
        onRetryCapture: (() -> Void)? = nil,
        onCancelCapture: (() -> Void)? = nil
    ) {
        _document = document
        self.saveState = saveState
        self.onDocumentChanged = onDocumentChanged
        self.onRetry = onRetry
        self.capturePresentation = capturePresentation
        self.captureKindsByBlockID = captureKindsByBlockID
        self.onCapture = onCapture
        self.onRetryCapture = onRetryCapture
        self.onCancelCapture = onCancelCapture
    }

    var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider()

            if document.blocks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    Text("Empty text document")
                        .font(.title3.weight(.semibold))

                    Text("Add a block to start writing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        addBlock(style: .body, after: nil)
                    } label: {
                        Label("Add text block", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("text-document.empty.add")
                }
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(document.blocks) { block in
                            blockRow(block)
                                .id(block.id)
                        }

                        Button {
                            addBlock(style: .body, after: document.blocks.last?.id)
                        } label: {
                            Label("Add block", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .disabled(document.blocks.count >= TextDocumentEditing.maximumBlockCount)
                        .padding(.vertical, 8)
                        .accessibilityHint("Adds a body block at the end of the document.")
                    }
                    .frame(maxWidth: 860)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(Color(uiColor: .systemBackground))
            }
        }
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            captureMarkerInset
        }
        .onChange(of: focusedBlockID) { _, blockID in
            guard let blockID,
                  capturePresentation?.isEnabled == true,
                  !captureTargetIsLocked
            else { return }
            captureTargetBlockID = blockID
        }
        .onChange(of: document.blocks.map(\.id)) { _, blockIDs in
            if let focusedBlockID, !blockIDs.contains(focusedBlockID) {
                self.focusedBlockID = nil
            }
            if let captureTargetBlockID, !blockIDs.contains(captureTargetBlockID) {
                self.captureTargetBlockID = nil
            }
        }
        .onChange(of: capturePresentation?.isEnabled) { _, isEnabled in
            guard isEnabled == true else {
                captureTargetBlockID = nil
                isDispatchingCaptureAction = false
                return
            }
            if let focusedBlockID {
                captureTargetBlockID = focusedBlockID
            }
        }
        .onChange(of: capturePresentation?.phase) { previousPhase, phase in
            isDispatchingCaptureAction = false
            guard previousPhase?.retainsCaptureTarget == true,
                  phase?.retainsCaptureTarget != true,
                  let focusedBlockID
            else { return }
            captureTargetBlockID = focusedBlockID
        }
        .confirmationDialog(
            "Replace text block with a divider?",
            isPresented: dividerConfirmationBinding,
            titleVisibility: .visible
        ) {
            if let blockID = pendingDividerBlockID {
                Button("Replace with divider", role: .destructive) {
                    pendingDividerBlockID = nil
                    changeStyle(of: blockID, to: .divider)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDividerBlockID = nil
            }
        } message: {
            Text("The text in this block will be removed.")
        }
    }

    private var editorToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                editorTitle
                Spacer(minLength: 12)
                saveIndicator
                appendBlockMenu
            }

            VStack(alignment: .leading, spacing: 8) {
                editorTitle
                HStack(spacing: 12) {
                    saveIndicator
                    Spacer(minLength: 12)
                    appendBlockMenu
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    @ViewBuilder
    private var captureMarkerInset: some View {
        if let capturePresentation,
           let captureTargetBlockID = eligibleCaptureTargetBlockID,
           onCapture != nil {
            TextDocumentCaptureMarkerBar(
                presentation: capturePresentation,
                isLocallyDispatching: isDispatchingCaptureAction,
                onCapture: { kind in
                    dispatchCapture(kind: kind, blockID: captureTargetBlockID)
                },
                onRetry: onRetryCapture.map { retry in
                    { dispatchCaptureRetry(retry) }
                },
                onCancel: onCancelCapture.map { cancel in
                    { dispatchCaptureCancel(cancel) }
                }
            )
        }
    }

    private var eligibleCaptureTargetBlockID: TextBlockID? {
        guard capturePresentation?.isEnabled == true else { return nil }
        return TextDocumentCaptureTargeting.eligibleBlockID(
            preferredBlockID: captureTargetBlockID,
            in: document
        )
    }

    private var captureTargetIsLocked: Bool {
        isDispatchingCaptureAction
            || capturePresentation?.phase.retainsCaptureTarget == true
    }

    private func dispatchCapture(kind: CaptureKind, blockID: TextBlockID) {
        guard !isDispatchingCaptureAction,
              capturePresentation?.phase.disablesMarkerControls == false,
              eligibleCaptureTargetBlockID == blockID,
              let onCapture
        else { return }

        captureTargetBlockID = blockID
        isDispatchingCaptureAction = true
        onCapture(blockID, kind)
        releaseDispatchGuardIfPresentationDidNotAdvance(
            from: capturePresentation?.phase
        )
    }

    private func dispatchCaptureRetry(_ retry: @escaping () -> Void) {
        guard !isDispatchingCaptureAction,
              capturePresentation?.phase.isFailure == true
        else { return }

        isDispatchingCaptureAction = true
        retry()
        releaseDispatchGuardIfPresentationDidNotAdvance(
            from: capturePresentation?.phase
        )
    }

    private func dispatchCaptureCancel(_ cancel: @escaping () -> Void) {
        guard !isDispatchingCaptureAction,
              capturePresentation?.phase.isFailure == true
        else { return }

        isDispatchingCaptureAction = true
        cancel()
        releaseDispatchGuardIfPresentationDidNotAdvance(
            from: capturePresentation?.phase
        )
    }

    private func releaseDispatchGuardIfPresentationDidNotAdvance(
        from phase: TextDocumentCapturePhase?
    ) {
        Task { @MainActor in
            await Task<Never, Never>.yield()
            guard capturePresentation?.phase == phase else { return }
            isDispatchingCaptureAction = false
        }
    }

    private var editorTitle: some View {
        Label("Text document", systemImage: "doc.text")
            .font(.headline)
    }

    private var appendBlockMenu: some View {
        Menu {
            ForEach(TextBlockStyle.allCases, id: \.self) { style in
                Button {
                    addBlock(style: style, after: document.blocks.last?.id)
                } label: {
                    Label(style.localizedTitle, systemImage: style.symbolName)
                }
            }
        } label: {
            Label("Add block", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .disabled(document.blocks.count >= TextDocumentEditing.maximumBlockCount)
        .accessibilityLabel("Add text block")
        .accessibilityHint("Choose a block style to append to the document.")
    }

    @ViewBuilder
    private var saveIndicator: some View {
        switch saveState {
        case .idle:
            EmptyView()
        case .saving:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Saving document")
            .accessibilityIdentifier("text-document.save.saving")
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityLabel("Document saved")
                .accessibilityIdentifier("text-document.save.saved")
        case .failed:
            Button(action: onRetry) {
                Label("Retry save", systemImage: "arrow.clockwise.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityLabel("Document save failed. Retry save")
            .accessibilityHint("Attempts to save the document again.")
            .accessibilityIdentifier("text-document.save.failed")
        }
    }

    private func blockRow(_ block: TextBlock) -> some View {
        HStack(alignment: .top, spacing: 10) {
            blockPrefix(block)

            if block.style == .divider {
                Divider()
                    .padding(.top, 22)
                    .accessibilityHidden(true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(
                        block.style.placeholder,
                        text: textBinding(for: block.id),
                        axis: .vertical
                    )
                    .font(block.style.font)
                    .lineLimit(block.style == .title ? 1...3 : 1...12)
                    .textFieldStyle(.plain)
                    .frame(minHeight: 44, alignment: .top)
                    .focused($focusedBlockID, equals: block.id)
                    .accessibilityLabel(block.style.localizedTitle)
                    .accessibilityHint("Edits this text block.")
                    .accessibilityIdentifier("text-document.block.input")

                    if let captureKinds = captureKindsByBlockID[block.id],
                       !captureKinds.isEmpty {
                        TextDocumentCaptureBadges(
                            blockID: block.id,
                            kinds: captureKinds
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            blockActions(block)
        }
        .padding(12)
        .padding(.leading, visualIndentation(for: block.indentationLevel))
        .background(block.style.rowBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func blockPrefix(_ block: TextBlock) -> some View {
        switch block.style {
        case .bulletedList:
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .frame(width: 32, height: 44)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case .numberedList:
            Text(verbatim: "\(TextDocumentEditing.numberedOrdinal(for: block.id, in: document)).")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 32, minHeight: 44, alignment: .topTrailing)
                .accessibilityHidden(true)
        case .checklist:
            Button {
                let currentState = document.blocks.first(where: { $0.id == block.id })?.isChecked ?? false
                setChecklistState(!currentState, blockID: block.id)
            } label: {
                Image(systemName: block.isChecked == true ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(block.isChecked == true ? "Mark item incomplete" : "Mark item complete")
            .accessibilityValue(block.isChecked == true ? "Completed" : "Not completed")
        case .quote:
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: 4, height: 44)
                .accessibilityHidden(true)
        default:
            EmptyView()
        }
    }

    private func blockActions(_ block: TextBlock) -> some View {
        let index = document.blocks.firstIndex(where: { $0.id == block.id })

        return Menu {
            Menu {
                ForEach(TextBlockStyle.allCases, id: \.self) { style in
                    Button {
                        requestStyleChange(of: block.id, to: style)
                    } label: {
                        Label {
                            Text(style.localizedTitle)
                        } icon: {
                            Image(systemName: style == block.style ? "checkmark" : style.symbolName)
                        }
                    }
                }
            } label: {
                Label("Block style", systemImage: "textformat")
            }

            Divider()

            Button {
                moveBlock(block.id, offset: -1)
            } label: {
                Label("Move up", systemImage: "arrow.up")
            }
            .disabled(index == nil || index == 0)

            Button {
                moveBlock(block.id, offset: 1)
            } label: {
                Label("Move down", systemImage: "arrow.down")
            }
            .disabled(index == nil || index == document.blocks.count - 1)

            Button {
                adjustIndentation(of: block.id, by: -1)
            } label: {
                Label("Outdent", systemImage: "decrease.indent")
            }
            .disabled(block.indentationLevel <= 0)

            Button {
                adjustIndentation(of: block.id, by: 1)
            } label: {
                Label("Indent", systemImage: "increase.indent")
            }
            .disabled(block.indentationLevel >= TextDocumentEditing.maximumIndentationLevel)

            Button {
                addBlock(style: .body, after: block.id)
            } label: {
                Label("Add block below", systemImage: "plus")
            }
            .disabled(document.blocks.count >= TextDocumentEditing.maximumBlockCount)

            Divider()

            Button(role: .destructive) {
                deleteBlock(block.id)
            } label: {
                Label("Delete block", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Block actions")
        .accessibilityValue(block.style.localizedTitle)
        .accessibilityHint("Change style, order, indentation, or delete this block.")
    }

    private func textBinding(for blockID: TextBlockID) -> Binding<String> {
        Binding(
            get: {
                document.blocks.first(where: { $0.id == blockID })?.text ?? ""
            },
            set: { text in
                apply(TextDocumentEditing.settingText(text, for: blockID, in: document))
            }
        )
    }

    private func addBlock(style: TextBlockStyle, after blockID: TextBlockID?) {
        let newBlock = TextDocumentEditing.makeBlock(style: style)
        let updated = TextDocumentEditing.inserting(newBlock, after: blockID, in: document)
        apply(updated)
        guard style != .divider else { return }
        Task { @MainActor in
            await Task<Never, Never>.yield()
            guard document.blocks.contains(where: { $0.id == newBlock.id }) else { return }
            focusedBlockID = newBlock.id
        }
    }

    private func deleteBlock(_ blockID: TextBlockID) {
        apply(TextDocumentEditing.deleting(blockID, from: document))
    }

    private func moveBlock(_ blockID: TextBlockID, offset: Int) {
        apply(TextDocumentEditing.moving(blockID, by: offset, in: document))
    }

    private func changeStyle(of blockID: TextBlockID, to style: TextBlockStyle) {
        apply(TextDocumentEditing.changingStyle(of: blockID, to: style, in: document))
        if style == .divider, focusedBlockID == blockID {
            focusedBlockID = nil
        }
        if style == .divider, captureTargetBlockID == blockID {
            captureTargetBlockID = nil
        }
    }

    private func requestStyleChange(of blockID: TextBlockID, to style: TextBlockStyle) {
        let block = document.blocks.first(where: { $0.id == blockID })
        guard style == .divider, block?.text.isEmpty == false else {
            changeStyle(of: blockID, to: style)
            return
        }
        pendingDividerBlockID = blockID
    }

    private func adjustIndentation(of blockID: TextBlockID, by offset: Int) {
        apply(TextDocumentEditing.adjustingIndentation(of: blockID, by: offset, in: document))
    }

    private func setChecklistState(_ isChecked: Bool, blockID: TextBlockID) {
        apply(TextDocumentEditing.settingChecklistState(isChecked, for: blockID, in: document))
    }

    private func apply(_ updatedDocument: TextDocument) {
        guard updatedDocument != document else { return }
        document = updatedDocument
        onDocumentChanged(updatedDocument)
    }

    private func visualIndentation(for indentationLevel: Int) -> CGFloat {
        CGFloat(min(max(indentationLevel, 0), 8)) * 12
    }

    private var dividerConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDividerBlockID != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDividerBlockID = nil
                }
            }
        )
    }
}

enum TextDocumentEditing {
    static let maximumBlockCount = 25_000
    static let maximumIndentationLevel = 32

    static func makeBlock(
        style: TextBlockStyle,
        id: TextBlockID = TextBlockID(),
        now: Date = Date()
    ) -> TextBlock {
        normalized(
            TextBlock(
                id: id,
                style: style,
                text: "",
                indentationLevel: 0,
                isChecked: style == .checklist ? false : nil,
                createdAt: now,
                modifiedAt: now
            )
        )
    }

    static func settingText(
        _ text: String,
        for blockID: TextBlockID,
        in document: TextDocument,
        now: Date = Date()
    ) -> TextDocument {
        updatingBlock(blockID, in: document, now: now) { block in
            block.text = block.style == .divider ? "" : text
        }
    }

    static func changingStyle(
        of blockID: TextBlockID,
        to style: TextBlockStyle,
        in document: TextDocument,
        now: Date = Date()
    ) -> TextDocument {
        updatingBlock(blockID, in: document, now: now) { block in
            block.style = style
        }
    }

    static func settingChecklistState(
        _ isChecked: Bool,
        for blockID: TextBlockID,
        in document: TextDocument,
        now: Date = Date()
    ) -> TextDocument {
        updatingBlock(blockID, in: document, now: now) { block in
            guard block.style == .checklist else { return }
            block.isChecked = isChecked
        }
    }

    static func adjustingIndentation(
        of blockID: TextBlockID,
        by offset: Int,
        in document: TextDocument,
        now: Date = Date()
    ) -> TextDocument {
        updatingBlock(blockID, in: document, now: now) { block in
            let (proposed, overflow) = block.indentationLevel.addingReportingOverflow(offset)
            let bounded = overflow ? (offset >= 0 ? Int.max : Int.min) : proposed
            block.indentationLevel = min(max(bounded, 0), maximumIndentationLevel)
        }
    }

    static func inserting(
        _ block: TextBlock,
        after precedingBlockID: TextBlockID?,
        in document: TextDocument
    ) -> TextDocument {
        guard document.blocks.count < maximumBlockCount,
              !document.blocks.contains(where: { $0.id == block.id }) else { return document }

        var updated = document
        let insertionIndex: Int
        if let precedingBlockID {
            guard let index = updated.blocks.firstIndex(where: { $0.id == precedingBlockID }) else {
                return document
            }
            insertionIndex = index + 1
        } else {
            insertionIndex = updated.blocks.endIndex
        }
        updated.blocks.insert(normalized(block), at: insertionIndex)
        return updated
    }

    static func deleting(_ blockID: TextBlockID, from document: TextDocument) -> TextDocument {
        guard document.blocks.contains(where: { $0.id == blockID }) else { return document }
        var updated = document
        updated.blocks.removeAll { $0.id == blockID }
        return updated
    }

    static func moving(
        _ blockID: TextBlockID,
        by offset: Int,
        in document: TextDocument,
        now: Date = Date()
    ) -> TextDocument {
        guard offset != 0,
              let sourceIndex = document.blocks.firstIndex(where: { $0.id == blockID })
        else { return document }

        let (destinationIndex, overflow) = sourceIndex.addingReportingOverflow(offset)
        guard !overflow else { return document }
        guard document.blocks.indices.contains(destinationIndex) else { return document }

        var updated = document
        var movedBlock = updated.blocks.remove(at: sourceIndex)
        touch(&movedBlock, now: now)
        updated.blocks.insert(movedBlock, at: destinationIndex)
        return updated
    }

    static func numberedOrdinal(for blockID: TextBlockID, in document: TextDocument) -> Int {
        guard let index = document.blocks.firstIndex(where: { $0.id == blockID }),
              document.blocks[index].style == .numberedList
        else { return 1 }

        let indentationLevel = document.blocks[index].indentationLevel
        var ordinal = 1
        var precedingIndex = index - 1
        while precedingIndex >= 0 {
            let preceding = document.blocks[precedingIndex]
            guard preceding.style == .numberedList,
                  preceding.indentationLevel == indentationLevel
            else { break }
            ordinal += 1
            precedingIndex -= 1
        }
        return ordinal
    }

    private static func updatingBlock(
        _ blockID: TextBlockID,
        in document: TextDocument,
        now: Date,
        mutation: (inout TextBlock) -> Void
    ) -> TextDocument {
        guard let index = document.blocks.firstIndex(where: { $0.id == blockID }) else {
            return document
        }

        let original = document.blocks[index]
        var updatedBlock = original
        mutation(&updatedBlock)
        updatedBlock = normalized(updatedBlock)
        guard updatedBlock != original else { return document }
        touch(&updatedBlock, now: now)

        var updatedDocument = document
        updatedDocument.blocks[index] = updatedBlock
        return updatedDocument
    }

    private static func normalized(_ block: TextBlock) -> TextBlock {
        var updated = block
        updated.indentationLevel = min(max(updated.indentationLevel, 0), maximumIndentationLevel)
        if updated.style == .checklist {
            updated.isChecked = updated.isChecked ?? false
        } else {
            updated.isChecked = nil
        }
        if updated.style == .divider {
            updated.text = ""
        }
        return updated
    }

    private static func touch(_ block: inout TextBlock, now: Date) {
        block.modifiedAt = max(block.modifiedAt, max(block.createdAt, now))
    }
}

private extension TextBlockStyle {
    var localizedTitle: String {
        switch self {
        case .title: String(localized: "Title")
        case .heading1: String(localized: "Heading 1")
        case .heading2: String(localized: "Heading 2")
        case .heading3: String(localized: "Heading 3")
        case .body: String(localized: "Body")
        case .bulletedList: String(localized: "Bulleted list")
        case .numberedList: String(localized: "Numbered list")
        case .checklist: String(localized: "Checklist")
        case .quote: String(localized: "Quote")
        case .code: String(localized: "Code")
        case .divider: String(localized: "Divider")
        }
    }

    var placeholder: String {
        switch self {
        case .title: String(localized: "Document title")
        case .heading1, .heading2, .heading3: String(localized: "Heading")
        case .bulletedList, .numberedList: String(localized: "List item")
        case .checklist: String(localized: "Task")
        case .quote: String(localized: "Quote")
        case .code: String(localized: "Code")
        case .body: String(localized: "Write something…")
        case .divider: ""
        }
    }

    var symbolName: String {
        switch self {
        case .title: "textformat.size"
        case .heading1, .heading2, .heading3: "textformat.size"
        case .body: "textformat"
        case .bulletedList: "list.bullet"
        case .numberedList: "list.number"
        case .checklist: "checklist"
        case .quote: "quote.opening"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .divider: "minus"
        }
    }

    var font: Font {
        switch self {
        case .title: .largeTitle.bold()
        case .heading1: .title.bold()
        case .heading2: .title2.bold()
        case .heading3: .title3.weight(.semibold)
        case .quote: .body.italic()
        case .code: .body.monospaced()
        default: .body
        }
    }

    var rowBackground: Color {
        switch self {
        case .code:
            Color(uiColor: .tertiarySystemBackground)
        case .quote:
            Color.accentColor.opacity(0.06)
        default:
            Color(uiColor: .secondarySystemBackground)
        }
    }
}
