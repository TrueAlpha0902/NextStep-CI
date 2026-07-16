import SwiftUI
import UIKit
import NotesCore

/// A structured, editable layer that can be placed above the PencilKit canvas.
///
/// Gesture updates are rendered from an immutable baseline. The binding and persistence callback
/// are touched only once, when a gesture ends or a discrete command succeeds.
struct CanvasElementLayerView: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding private var elements: [CanvasElement]

    let pageBounds: CanvasRect
    let assetImageResolver: (AssetID, CanvasElementImageRequest) -> UIImage?
    let onElementsChanged: ([CanvasElement]) -> Void

    @State private var selectedIDs = Set<ElementID>()
    @State private var isExtendingSelection = false
    @State private var activeGesture: CanvasElementGestureCommitModel?
    @State private var editorTarget: CanvasElementEditorTarget?

    private let coordinateSpaceName = "notes.canvas-element-layer"

    init(
        elements: Binding<[CanvasElement]>,
        pageBounds: CanvasRect,
        assetImageResolver: @escaping (AssetID, CanvasElementImageRequest) -> UIImage? = { _, _ in nil },
        onElementsChanged: @escaping ([CanvasElement]) -> Void
    ) {
        _elements = elements
        self.pageBounds = pageBounds
        self.assetImageResolver = assetImageResolver
        self.onElementsChanged = onElementsChanged
    }

    var body: some View {
        GeometryReader { proxy in
            let transform = CanvasElementCoordinateTransform(
                pageBounds: pageBounds,
                viewSize: proxy.size
            )
            let entries = renderEntries

            ZStack(alignment: .topLeading) {
                Color.clear
                    .allowsHitTesting(false)

                ForEach(entries) { entry in
                    elementView(
                        entry.element,
                        renderIdentity: entry.id,
                        hasUnambiguousIdentity: entry.hasUnambiguousIdentity,
                        transform: transform
                    )
                }

                if !selectedIDs.isEmpty {
                    selectionToolbar
                        .padding()
                        .zIndex(Double.greatestFiniteMagnitude)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .coordinateSpace(name: coordinateSpaceName)
            .clipped()
            // An empty structured layer must not steal touch or Pencil input from PencilKit.
            .allowsHitTesting(!entries.isEmpty)
        }
        .sheet(item: $editorTarget) { target in
            if let element = elements.first(where: { $0.id == target.id }) {
                CanvasElementEditorSheet(element: element) { content in
                    updateContent(content, for: target.id)
                }
            }
        }
        .onChange(of: elements) { _, newElements in
            if let activeGesture,
               activeGesture.baselineElements != newElements {
                // Never let a gesture that began against stale state overwrite an external edit.
                self.activeGesture = nil
            }
            let availableIDs = Set(newElements.map(\.id))
            selectedIDs.formIntersection(availableIDs)
            if let target = editorTarget {
                let targetCount = newElements.lazy
                    .filter { $0.id == target.id }
                    .prefix(2)
                    .count
                if targetCount != 1 {
                    editorTarget = nil
                }
            }
        }
        .accessibilityIdentifier("canvas.element.layer")
    }

    private var renderedElements: [CanvasElement] {
        let source = activeGesture?.previewElements() ?? elements
        return CanvasElementEditing.normalized(
            source,
            within: pageBounds,
            now: source.map(\.modifiedAt).max() ?? .distantPast
        )
    }

    private var renderEntries: [CanvasElementRenderEntry] {
        CanvasElementRenderEntry.entries(for: renderedElements)
    }

    private var ambiguousElementIDs: Set<ElementID> {
        let groups = Dictionary(grouping: elements, by: \.id)
        var result = Set<ElementID>()
        for (id, matches) in groups where matches.count != 1 {
            result.insert(id)
        }
        return result
    }

    private var selectionContainsAmbiguousIdentity: Bool {
        !selectedIDs.isDisjoint(with: ambiguousElementIDs)
    }

    @ViewBuilder
    private func elementView(
        _ element: CanvasElement,
        renderIdentity: CanvasElementRenderEntry.ID,
        hasUnambiguousIdentity: Bool,
        transform: CanvasElementCoordinateTransform
    ) -> some View {
        let localFrame = transform.localRect(for: element.frame)
        let isSelected = selectedIDs.contains(element.id)
        let presentation = CanvasElementPresentationModel(element: element)

        CanvasElementContentView(
            element: element,
            imageRequest: CanvasElementImageRequest(
                displaySize: localFrame.size,
                displayScale: displayScale
            ),
            assetImageResolver: assetImageResolver
        )
        .frame(
            width: max(1, localFrame.width),
            height: max(1, localFrame.height)
        )
        .overlay {
            if isSelected {
                CanvasElementSelectionOverlay(
                    element: element,
                    showsHandles: selectedIDs.count == 1
                        && hasUnambiguousIdentity
                        && !element.isLocked,
                    coordinateSpaceName: coordinateSpaceName,
                    onResizeChanged: { handle, value in
                        updateResize(
                            element: element,
                            hasUnambiguousIdentity: hasUnambiguousIdentity,
                            handle: handle,
                            translation: transform.pageTranslation(for: value.translation)
                        )
                    },
                    onResizeEnded: { handle, value in
                        finishResize(
                            element: element,
                            hasUnambiguousIdentity: hasUnambiguousIdentity,
                            handle: handle,
                            translation: transform.pageTranslation(for: value.translation)
                        )
                    },
                    onRotationChanged: { value in
                        updateRotation(
                            element: element,
                            hasUnambiguousIdentity: hasUnambiguousIdentity,
                            start: transform.pagePoint(for: value.startLocation),
                            current: transform.pagePoint(for: value.location)
                        )
                    },
                    onRotationEnded: { value in
                        finishRotation(
                            element: element,
                            hasUnambiguousIdentity: hasUnambiguousIdentity,
                            start: transform.pagePoint(for: value.startLocation),
                            current: transform.pagePoint(for: value.location)
                        )
                    }
                )
            }
        }
        .contentShape(Rectangle())
        .rotationEffect(.radians(element.rotationRadians))
        .position(x: localFrame.midX, y: localFrame.midY)
        .zIndex(Double(element.zIndex))
        .hoverEffect(.highlight)
        .gesture(elementDragGesture(
            for: element,
            hasUnambiguousIdentity: hasUnambiguousIdentity,
            transform: transform
        ))
        .onTapGesture(count: 2) {
            beginEditing(element, hasUnambiguousIdentity: hasUnambiguousIdentity)
        }
        .onTapGesture {
            select(element.id)
        }
        .contextMenu {
            elementContextMenu(element, hasUnambiguousIdentity: hasUnambiguousIdentity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: presentation.title))
        .accessibilityValue(Text(verbatim: presentation.accessibilityValue(isLocked: element.isLocked)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(renderIdentity.accessibilityIdentifier(
            hasUnambiguousIdentity: hasUnambiguousIdentity
        ))
        .accessibilityAction(named: Text("Select")) {
            select(element.id)
        }
        .canvasElementEditAccessibilityAction(
            isEnabled: hasUnambiguousIdentity
                && element.content.isInlineEditable
                && !element.isLocked
        ) {
            beginEditing(element, hasUnambiguousIdentity: hasUnambiguousIdentity)
        }
    }

    private func elementDragGesture(
        for element: CanvasElement,
        hasUnambiguousIdentity: Bool,
        transform: CanvasElementCoordinateTransform
    ) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(coordinateSpaceName))
            .onChanged { value in
                guard hasUnambiguousIdentity, !element.isLocked else { return }
                let ids = selectedIDs.contains(element.id) && !selectionContainsAmbiguousIdentity
                    ? selectedIDs
                    : Set([element.id])
                if selectedIDs != ids { selectedIDs = ids }
                let offset = transform.pageTranslation(for: value.translation)
                activeGesture = CanvasElementGestureCommitModel(
                    baselineElements: activeGesture?.baselineElements ?? elements,
                    pageBounds: pageBounds,
                    operation: .translation(selectedIDs: ids, offset: offset)
                )
            }
            .onEnded { value in
                guard hasUnambiguousIdentity, !element.isLocked else { return }
                let ids = selectedIDs.contains(element.id) && !selectionContainsAmbiguousIdentity
                    ? selectedIDs
                    : Set([element.id])
                let offset = transform.pageTranslation(for: value.translation)
                let model = CanvasElementGestureCommitModel(
                    baselineElements: activeGesture?.baselineElements ?? elements,
                    pageBounds: pageBounds,
                    operation: .translation(selectedIDs: ids, offset: offset)
                )
                finishGesture(model)
            }
    }

    private func updateResize(
        element: CanvasElement,
        hasUnambiguousIdentity: Bool,
        handle: CanvasElementResizeHandle,
        translation: CanvasPoint
    ) {
        guard hasUnambiguousIdentity, !element.isLocked else { return }
        let baseline = activeGesture?.baselineElements ?? elements
        guard let source = baseline.first(where: { $0.id == element.id }) else { return }
        activeGesture = CanvasElementGestureCommitModel(
            baselineElements: baseline,
            pageBounds: pageBounds,
            operation: .resize(
                id: element.id,
                proposedFrame: handle.proposedFrame(from: source.frame, translation: translation),
                preservesAspectRatio: source.content.prefersAspectPreservingResize
            )
        )
    }

    private func finishResize(
        element: CanvasElement,
        hasUnambiguousIdentity: Bool,
        handle: CanvasElementResizeHandle,
        translation: CanvasPoint
    ) {
        updateResize(
            element: element,
            hasUnambiguousIdentity: hasUnambiguousIdentity,
            handle: handle,
            translation: translation
        )
        guard let activeGesture else { return }
        finishGesture(activeGesture)
    }

    private func updateRotation(
        element: CanvasElement,
        hasUnambiguousIdentity: Bool,
        start: CanvasPoint,
        current: CanvasPoint
    ) {
        guard hasUnambiguousIdentity, !element.isLocked else { return }
        let baseline = activeGesture?.baselineElements ?? elements
        guard let source = baseline.first(where: { $0.id == element.id }) else { return }
        let center = CanvasPoint(
            x: source.frame.x + source.frame.width / 2,
            y: source.frame.y + source.frame.height / 2
        )
        activeGesture = CanvasElementGestureCommitModel(
            baselineElements: baseline,
            pageBounds: pageBounds,
            operation: .rotation(
                selectedIDs: selectedIDs.isEmpty ? Set([element.id]) : selectedIDs,
                radians: CanvasElementGestureCommitModel.rotationDelta(
                    around: center,
                    start: start,
                    current: current
                )
            )
        )
    }

    private func finishRotation(
        element: CanvasElement,
        hasUnambiguousIdentity: Bool,
        start: CanvasPoint,
        current: CanvasPoint
    ) {
        updateRotation(
            element: element,
            hasUnambiguousIdentity: hasUnambiguousIdentity,
            start: start,
            current: current
        )
        guard let activeGesture else { return }
        finishGesture(activeGesture)
    }

    private func finishGesture(_ model: CanvasElementGestureCommitModel) {
        let committed = model.committedElements(now: Date())
        activeGesture = nil
        commit(committed)
    }

    private func select(_ id: ElementID) {
        if isExtendingSelection {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
        } else {
            selectedIDs = Set([id])
        }
    }

    private func beginEditing(
        _ element: CanvasElement,
        hasUnambiguousIdentity: Bool? = nil
    ) {
        let isUnambiguous = hasUnambiguousIdentity
            ?? (elements.lazy.filter { $0.id == element.id }.prefix(2).count == 1)
        guard isUnambiguous,
              element.content.isInlineEditable,
              !element.isLocked else { return }
        selectedIDs = Set([element.id])
        editorTarget = CanvasElementEditorTarget(id: element.id)
    }

    private func updateContent(_ content: CanvasElementContent, for id: ElementID) {
        let updated = CanvasElementEditing.updatingContent(
            of: id,
            to: content,
            in: elements,
            within: pageBounds,
            now: Date()
        )
        commit(updated)
    }

    private func toggleTapeReveal(_ element: CanvasElement) {
        guard case .tape(var tape) = element.content else { return }
        tape.isRevealed.toggle()
        updateContent(.tape(tape), for: element.id)
    }

    private func commit(_ updated: [CanvasElement]) {
        guard updated != elements else { return }
        elements = updated
        let remainingIDs = Set(updated.map(\.id))
        selectedIDs.formIntersection(remainingIDs)
        onElementsChanged(updated)
    }

    private var selectedElements: [CanvasElement] {
        elements.filter { selectedIDs.contains($0.id) }
    }

    private var allSelectedAreLocked: Bool {
        !selectedElements.isEmpty && selectedElements.allSatisfy(\.isLocked)
    }

    private var selectionToolbar: some View {
        ScrollView(
            .horizontal,
            showsIndicators: horizontalSizeClass == .compact
        ) {
            HStack(spacing: 6) {
                toolbarButton(
                    symbol: isExtendingSelection ? "checkmark.circle.fill" : "selection.pin.in.out",
                    label: isExtendingSelection ? "Finish multiple selection" : "Select multiple",
                    identifier: "multiple-selection",
                    action: { isExtendingSelection.toggle() }
                )
                .keyboardShortcut("m", modifiers: .command)

                if selectedIDs.count == 1,
                   let element = selectedElements.first,
                   !selectionContainsAmbiguousIdentity,
                   element.content.isInlineEditable,
                   !element.isLocked {
                    toolbarButton(symbol: "pencil", label: "Edit", identifier: "edit") {
                        beginEditing(element)
                    }
                    .keyboardShortcut(.return, modifiers: [])
                }

                toolbarButton(
                    symbol: allSelectedAreLocked ? "lock.open" : "lock",
                    label: allSelectedAreLocked ? "Unlock" : "Lock",
                    identifier: "lock"
                ) {
                    let updated = CanvasElementEditing.settingLocked(
                        !allSelectedAreLocked,
                        for: selectedIDs,
                        in: elements,
                        within: pageBounds,
                        now: Date()
                    )
                    commit(updated)
                }
                .disabled(selectionContainsAmbiguousIdentity)
                .keyboardShortcut("l", modifiers: .command)

                toolbarButton(
                    symbol: "square.3.layers.3d.bottom.filled",
                    label: "Send to back",
                    identifier: "send-to-back"
                ) {
                    commit(CanvasElementEditing.sendingToBack(
                        selectedIDs,
                        in: elements,
                        within: pageBounds,
                        now: Date()
                    ))
                }
                .disabled(allSelectedAreLocked || selectionContainsAmbiguousIdentity)

                toolbarButton(
                    symbol: "square.3.layers.3d.top.filled",
                    label: "Bring to front",
                    identifier: "bring-to-front"
                ) {
                    commit(CanvasElementEditing.bringingToFront(
                        selectedIDs,
                        in: elements,
                        within: pageBounds,
                        now: Date()
                    ))
                }
                .disabled(allSelectedAreLocked || selectionContainsAmbiguousIdentity)

                toolbarButton(
                    symbol: "plus.square.on.square",
                    label: "Duplicate",
                    identifier: "duplicate"
                ) {
                    duplicateSelection()
                }
                .disabled(allSelectedAreLocked || selectionContainsAmbiguousIdentity)
                .keyboardShortcut("d", modifiers: .command)

                toolbarButton(
                    symbol: "trash",
                    label: "Delete",
                    identifier: "delete",
                    role: .destructive
                ) {
                    deleteSelection()
                }
                .disabled(allSelectedAreLocked || selectionContainsAmbiguousIdentity)
                .keyboardShortcut(.delete, modifiers: [])

                toolbarButton(
                    symbol: "xmark",
                    label: "Clear selection",
                    identifier: "clear-selection"
                ) {
                    selectedIDs.removeAll()
                    isExtendingSelection = false
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("canvas.element.selection-toolbar")
    }

    private func toolbarButton(
        symbol: String,
        label: LocalizedStringKey,
        identifier: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .frame(minWidth: 32, minHeight: 32)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier("canvas.element.action.\(identifier)")
    }

    @ViewBuilder
    private func elementContextMenu(
        _ element: CanvasElement,
        hasUnambiguousIdentity: Bool
    ) -> some View {
        if hasUnambiguousIdentity,
           element.content.isInlineEditable,
           !element.isLocked {
            contextMenuButton(symbol: "pencil", label: "Edit") {
                beginEditing(element)
            }
        }

        if hasUnambiguousIdentity,
           case .tape(let tape) = element.content,
           !element.isLocked {
            contextMenuButton(
                symbol: tape.isRevealed ? "eye.slash" : "eye",
                label: tape.isRevealed ? "Hide tape" : "Reveal tape"
            ) {
                toggleTapeReveal(element)
            }
        }

        contextMenuButton(
            symbol: selectedIDs.contains(element.id) ? "checkmark.circle" : "plus.circle",
            label: selectedIDs.contains(element.id) ? "Remove from selection" : "Add to selection"
        ) {
            if selectedIDs.contains(element.id) {
                selectedIDs.remove(element.id)
            } else {
                selectedIDs.insert(element.id)
            }
        }

        if hasUnambiguousIdentity {
            contextMenuButton(
                symbol: element.isLocked ? "lock.open" : "lock",
                label: element.isLocked ? "Unlock" : "Lock"
            ) {
                selectedIDs = Set([element.id])
                commit(CanvasElementEditing.settingLocked(
                    !element.isLocked,
                    for: Set([element.id]),
                    in: elements,
                    within: pageBounds,
                    now: Date()
                ))
            }
        }

        if hasUnambiguousIdentity, !element.isLocked {
            contextMenuButton(symbol: "square.3.layers.3d.top.filled", label: "Bring to front") {
                commit(CanvasElementEditing.bringingToFront(
                    Set([element.id]),
                    in: elements,
                    within: pageBounds,
                    now: Date()
                ))
            }

            contextMenuButton(symbol: "square.3.layers.3d.bottom.filled", label: "Send to back") {
                commit(CanvasElementEditing.sendingToBack(
                    Set([element.id]),
                    in: elements,
                    within: pageBounds,
                    now: Date()
                ))
            }

            contextMenuButton(symbol: "plus.square.on.square", label: "Duplicate") {
                selectedIDs = Set([element.id])
                duplicateSelection()
            }

            contextMenuButton(symbol: "trash", label: "Delete", role: .destructive) {
                selectedIDs = Set([element.id])
                deleteSelection()
            }
        }
    }

    private func contextMenuButton(
        symbol: String,
        label: LocalizedStringKey,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label {
                Text(label)
            } icon: {
                Image(systemName: symbol)
            }
        }
    }

    private func duplicateSelection() {
        var updated = elements
        var duplicatedIDs = Set<ElementID>()
        let now = Date()
        let orderedIDs = CanvasElementRenderEntry.entries(for: elements)
            .lazy
            .map(\.element)
            .filter { selectedIDs.contains($0.id) && !$0.isLocked }
            .map(\.id)
        for id in orderedIDs {
            guard updated.first(where: { $0.id == id })?.isLocked == false else { continue }
            let newID = ElementID()
            let next = CanvasElementEditing.duplicating(
                id,
                as: newID,
                in: updated,
                within: pageBounds,
                now: now
            )
            if next != updated {
                updated = next
                duplicatedIDs.insert(newID)
            }
        }
        if !duplicatedIDs.isEmpty { selectedIDs = duplicatedIDs }
        commit(updated)
    }

    private func deleteSelection() {
        var updated = elements
        let now = Date()
        let orderedIDs = CanvasElementRenderEntry.entries(for: elements)
            .lazy
            .map(\.element)
            .filter { selectedIDs.contains($0.id) && !$0.isLocked }
            .map(\.id)
        for id in orderedIDs {
            updated = CanvasElementEditing.deleting(
                id,
                from: updated,
                within: pageBounds,
                now: now
            )
        }
        commit(updated)
    }
}

// MARK: - Pure presentation and gesture models

struct CanvasElementRenderEntry: Identifiable, Equatable {
    struct ID: Hashable {
        let elementID: ElementID
        let occurrence: Int

        func accessibilityIdentifier(hasUnambiguousIdentity: Bool) -> String {
            let base = "canvas.element.\(elementID.description)"
            return hasUnambiguousIdentity ? base : "\(base).duplicate.\(occurrence)"
        }
    }

    let id: ID
    let element: CanvasElement
    let hasUnambiguousIdentity: Bool

    static func entries(for elements: [CanvasElement]) -> [Self] {
        let counts = Dictionary(grouping: elements, by: \.id).mapValues { $0.count }
        let ordered = elements.enumerated().sorted { lhs, rhs in
            if lhs.element.zIndex != rhs.element.zIndex {
                return lhs.element.zIndex < rhs.element.zIndex
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var occurrences = [ElementID: Int]()
        return ordered.map { element in
            let occurrence = occurrences[element.id, default: 0]
            occurrences[element.id] = occurrence + 1
            return Self(
                id: ID(elementID: element.id, occurrence: occurrence),
                element: element,
                hasUnambiguousIdentity: counts[element.id] == 1
            )
        }
    }
}

struct CanvasElementPresentationModel: Equatable {
    enum Kind: Equatable {
        case text, image, shape, connector, stickyNote, tape, sticker, link
    }

    let kind: Kind
    let title: String
    let symbolName: String
    let summary: String

    init(element: CanvasElement) {
        switch element.content {
        case .text(let text):
            self.init(
                kind: .text,
                title: String(localized: "Text"),
                symbolName: "textformat",
                summary: text.text
            )
        case .image:
            self.init(
                kind: .image,
                title: String(localized: "Image"),
                symbolName: "photo",
                summary: String(localized: "Embedded image")
            )
        case .shape(let shape):
            self.init(
                kind: .shape,
                title: String(localized: "Shape"),
                symbolName: "square.on.circle",
                summary: Self.localizedShapeName(shape.shape)
            )
        case .connector(let connector):
            self.init(
                kind: .connector,
                title: String(localized: "Connector"),
                symbolName: "arrow.up.right",
                summary: connector.endCap.lowercased().contains("arrow")
                    ? String(localized: "Arrow")
                    : String(localized: "Line")
            )
        case .stickyNote(let sticky):
            self.init(
                kind: .stickyNote,
                title: String(localized: "Sticky note"),
                symbolName: "note",
                summary: sticky.text
            )
        case .tape(let tape):
            self.init(
                kind: .tape,
                title: String(localized: "Tape"),
                symbolName: tape.isRevealed ? "eye" : "eye.slash",
                summary: tape.isRevealed
                    ? String(localized: "Revealed")
                    : String(localized: "Hidden")
            )
        case .sticker(let sticker):
            self.init(
                kind: .sticker,
                title: String(localized: "Sticker"),
                symbolName: "star.square",
                summary: sticker.accessibilityLabel ?? String(localized: "Embedded sticker")
            )
        case .link(let link):
            self.init(
                kind: .link,
                title: String(localized: "Link"),
                symbolName: "link",
                summary: link.title
            )
        }
    }

    private init(kind: Kind, title: String, symbolName: String, summary: String) {
        self.kind = kind
        self.title = title
        self.symbolName = symbolName
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func accessibilityValue(isLocked: Bool) -> String {
        let value = summary.isEmpty ? String(localized: "Empty") : summary
        guard isLocked else { return value }
        return String.localizedStringWithFormat(String(localized: "%@, locked"), value)
    }

    private static func localizedShapeName(_ rawValue: String) -> String {
        switch rawValue.lowercased() {
        case "ellipse": String(localized: "Ellipse")
        case "circle": String(localized: "Circle")
        case "rectangle": String(localized: "Rectangle")
        case "roundedrectangle", "rounded rectangle": String(localized: "Rounded rectangle")
        default: String(localized: "Shape")
        }
    }
}

struct CanvasElementCoordinateTransform: Equatable {
    let pageBounds: CanvasRect
    let viewSize: CGSize

    private static let minimumLogicalLength = 1e-9
    private static let maximumLogicalMagnitude = 1e12
    private static let maximumRenderableMagnitude = 1e6

    private var canonicalPageBounds: CanvasRect {
        let rawWidth = finiteLogical(pageBounds.width, fallback: 1)
        let rawHeight = finiteLogical(pageBounds.height, fallback: 1)
        let width = min(
            max(abs(rawWidth), Self.minimumLogicalLength),
            Self.maximumLogicalMagnitude
        )
        let height = min(
            max(abs(rawHeight), Self.minimumLogicalLength),
            Self.maximumLogicalMagnitude
        )
        var x = finiteLogical(pageBounds.x, fallback: 0)
        var y = finiteLogical(pageBounds.y, fallback: 0)
        if rawWidth < 0 { x = safeAdding(x, -width) }
        if rawHeight < 0 { y = safeAdding(y, -height) }
        return CanvasRect(x: x, y: y, width: width, height: height)
    }

    private var scaleX: Double {
        safeScale(viewLength: viewSize.width, logicalLength: canonicalPageBounds.width)
    }

    private var scaleY: Double {
        safeScale(viewLength: viewSize.height, logicalLength: canonicalPageBounds.height)
    }

    func localRect(for frame: CanvasRect) -> CGRect {
        let bounds = canonicalPageBounds
        let rawWidth = finiteLogical(frame.width, fallback: Self.minimumLogicalLength)
        let rawHeight = finiteLogical(frame.height, fallback: Self.minimumLogicalLength)
        let width = min(max(abs(rawWidth), Self.minimumLogicalLength), Self.maximumLogicalMagnitude)
        let height = min(max(abs(rawHeight), Self.minimumLogicalLength), Self.maximumLogicalMagnitude)
        var x = finiteLogical(frame.x, fallback: bounds.x)
        var y = finiteLogical(frame.y, fallback: bounds.y)
        if rawWidth < 0 { x = safeAdding(x, -width) }
        if rawHeight < 0 { y = safeAdding(y, -height) }

        return CGRect(
            x: CGFloat(finiteRenderable(safeMultiplying(safeAdding(x, -bounds.x), scaleX))),
            y: CGFloat(finiteRenderable(safeMultiplying(safeAdding(y, -bounds.y), scaleY))),
            width: CGFloat(finiteRenderable(safeMultiplying(width, scaleX), nonnegative: true)),
            height: CGFloat(finiteRenderable(safeMultiplying(height, scaleY), nonnegative: true))
        )
    }

    func pageTranslation(for localTranslation: CGSize) -> CanvasPoint {
        let localX = finiteRenderable(Double(localTranslation.width))
        let localY = finiteRenderable(Double(localTranslation.height))
        return CanvasPoint(
            x: finiteLogical(scaleX == 0 ? 0 : localX / scaleX, fallback: 0),
            y: finiteLogical(scaleY == 0 ? 0 : localY / scaleY, fallback: 0)
        )
    }

    func pagePoint(for localPoint: CGPoint) -> CanvasPoint {
        let bounds = canonicalPageBounds
        let localX = finiteRenderable(Double(localPoint.x))
        let localY = finiteRenderable(Double(localPoint.y))
        return CanvasPoint(
            x: safeAdding(bounds.x, scaleX == 0 ? 0 : localX / scaleX),
            y: safeAdding(bounds.y, scaleY == 0 ? 0 : localY / scaleY)
        )
    }

    private func safeScale(viewLength: CGFloat, logicalLength: Double) -> Double {
        guard viewLength.isFinite, viewLength > 0,
              logicalLength.isFinite, logicalLength > 0 else { return 0 }
        let boundedViewLength = min(Double(viewLength), Self.maximumRenderableMagnitude)
        let result = boundedViewLength / logicalLength
        guard result.isFinite else { return Self.maximumLogicalMagnitude }
        return min(max(result, 0), Self.maximumLogicalMagnitude)
    }

    private func finiteLogical(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, -Self.maximumLogicalMagnitude), Self.maximumLogicalMagnitude)
    }

    private func finiteRenderable(_ value: Double, nonnegative: Bool = false) -> Double {
        guard value.isFinite else { return 0 }
        let minimum = nonnegative ? 0 : -Self.maximumRenderableMagnitude
        return min(max(value, minimum), Self.maximumRenderableMagnitude)
    }

    private func safeAdding(_ lhs: Double, _ rhs: Double) -> Double {
        finiteLogical(lhs + rhs, fallback: rhs.sign == .minus
            ? -Self.maximumLogicalMagnitude
            : Self.maximumLogicalMagnitude)
    }

    private func safeMultiplying(_ lhs: Double, _ rhs: Double) -> Double {
        let result = lhs * rhs
        guard result.isFinite else {
            return lhs.sign == rhs.sign
                ? Self.maximumRenderableMagnitude
                : -Self.maximumRenderableMagnitude
        }
        return result
    }
}

enum CanvasElementResizeHandle: String, CaseIterable, Hashable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var symbolName: String {
        switch self {
        case .topLeading, .bottomTrailing: "arrow.up.left.and.arrow.down.right"
        case .topTrailing, .bottomLeading: "arrow.up.right.and.arrow.down.left"
        }
    }

    func localPosition(in size: CGSize) -> CGPoint {
        switch self {
        case .topLeading: CGPoint(x: 0, y: 0)
        case .topTrailing: CGPoint(x: size.width, y: 0)
        case .bottomLeading: CGPoint(x: 0, y: size.height)
        case .bottomTrailing: CGPoint(x: size.width, y: size.height)
        }
    }

    func proposedFrame(from frame: CanvasRect, translation: CanvasPoint) -> CanvasRect {
        let frame = CanvasRect(
            x: Self.finite(frame.x, fallback: 0),
            y: Self.finite(frame.y, fallback: 0),
            width: Self.finite(frame.width, fallback: CanvasElementEditing.minimumInteractiveLength),
            height: Self.finite(frame.height, fallback: CanvasElementEditing.minimumInteractiveLength)
        )
        let translation = CanvasPoint(
            x: Self.finite(translation.x, fallback: 0),
            y: Self.finite(translation.y, fallback: 0)
        )
        return switch self {
        case .topLeading:
            CanvasRect(
                x: Self.adding(frame.x, translation.x),
                y: Self.adding(frame.y, translation.y),
                width: Self.adding(frame.width, -translation.x),
                height: Self.adding(frame.height, -translation.y)
            )
        case .topTrailing:
            CanvasRect(
                x: frame.x,
                y: Self.adding(frame.y, translation.y),
                width: Self.adding(frame.width, translation.x),
                height: Self.adding(frame.height, -translation.y)
            )
        case .bottomLeading:
            CanvasRect(
                x: Self.adding(frame.x, translation.x),
                y: frame.y,
                width: Self.adding(frame.width, -translation.x),
                height: Self.adding(frame.height, translation.y)
            )
        case .bottomTrailing:
            CanvasRect(
                x: frame.x,
                y: frame.y,
                width: Self.adding(frame.width, translation.x),
                height: Self.adding(frame.height, translation.y)
            )
        }
    }

    private static let maximumMagnitude = 1e12

    private static func finite(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, -maximumMagnitude), maximumMagnitude)
    }

    private static func adding(_ lhs: Double, _ rhs: Double) -> Double {
        let result = lhs + rhs
        guard result.isFinite else {
            return rhs.sign == .minus ? -maximumMagnitude : maximumMagnitude
        }
        return finite(result, fallback: 0)
    }
}

struct CanvasElementGestureCommitModel: Equatable {
    enum Operation: Equatable {
        case translation(selectedIDs: Set<ElementID>, offset: CanvasPoint)
        case resize(
            id: ElementID,
            proposedFrame: CanvasRect,
            preservesAspectRatio: Bool
        )
        case rotation(selectedIDs: Set<ElementID>, radians: Double)
    }

    let baselineElements: [CanvasElement]
    let pageBounds: CanvasRect
    let operation: Operation

    func previewElements() -> [CanvasElement] {
        applying(now: baselineElements.map(\.modifiedAt).max() ?? .distantPast)
    }

    func committedElements(now: Date) -> [CanvasElement] {
        applying(now: now)
    }

    static func rotationDelta(
        around center: CanvasPoint,
        start: CanvasPoint,
        current: CanvasPoint
    ) -> Double {
        let startAngle = atan2(start.y - center.y, start.x - center.x)
        let currentAngle = atan2(current.y - center.y, current.x - center.x)
        guard startAngle.isFinite, currentAngle.isFinite else { return 0 }
        return currentAngle - startAngle
    }

    private func applying(now: Date) -> [CanvasElement] {
        switch operation {
        case .translation(let selectedIDs, let offset):
            CanvasElementEditing.translating(
                selectedIDs,
                by: offset,
                in: baselineElements,
                within: pageBounds,
                now: now
            )
        case .resize(let id, let proposedFrame, let preservesAspectRatio):
            CanvasElementEditing.resizing(
                id,
                to: proposedFrame,
                preservingAspectRatio: preservesAspectRatio,
                in: baselineElements,
                within: pageBounds,
                now: now
            )
        case .rotation(let selectedIDs, let radians):
            CanvasElementEditing.rotating(
                selectedIDs,
                by: radians,
                in: baselineElements,
                within: pageBounds,
                now: now
            )
        }
    }
}

// MARK: - Element rendering

/// The resolver is called from SwiftUI rendering and should return a cached thumbnail decoded
/// directly to this bounded size (for example with ImageIO), never synchronously decode the full
/// source. The layer also refuses images that exceed the request, so an integration cannot retain
/// an unnecessarily large texture by mistake.
struct CanvasElementImageRequest: Equatable, Hashable {
    static let maximumAllowedPixelDimension: CGFloat = 4_096

    let maximumPixelDimension: CGFloat

    init(displaySize: CGSize, displayScale: CGFloat) {
        let width = displaySize.width.isFinite ? abs(displaySize.width) : 0
        let height = displaySize.height.isFinite ? abs(displaySize.height) : 0
        let scale = displayScale.isFinite ? max(displayScale, 1) : 1
        let requested = max(width, height) * scale
        if requested.isFinite {
            maximumPixelDimension = min(
                max(requested.rounded(.up), 1),
                Self.maximumAllowedPixelDimension
            )
        } else {
            maximumPixelDimension = Self.maximumAllowedPixelDimension
        }
    }

    func accepts(_ image: UIImage) -> Bool {
        let pixelSize: CGSize
        if let cgImage = image.cgImage {
            pixelSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        } else {
            let scale = image.scale.isFinite ? max(image.scale, 1) : 1
            pixelSize = CGSize(
                width: image.size.width * scale,
                height: image.size.height * scale
            )
        }
        guard pixelSize.width.isFinite,
              pixelSize.height.isFinite,
              pixelSize.width > 0,
              pixelSize.height > 0 else { return false }
        return max(pixelSize.width, pixelSize.height) <= maximumPixelDimension
    }
}

private struct CanvasElementContentView: View {
    let element: CanvasElement
    let imageRequest: CanvasElementImageRequest
    let assetImageResolver: (AssetID, CanvasElementImageRequest) -> UIImage?

    var body: some View {
        Group {
            switch element.content {
            case .text(let text):
                Group {
                    if text.text.isEmpty {
                        Text("Text")
                    } else {
                        Text(verbatim: text.text)
                    }
                }
                .font(.system(size: CGFloat(max(8, min(text.fontSize, 160)))))
                .foregroundStyle(text.color.swiftUIColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
            case .image(let image):
                assetView(
                    assetID: image.assetID,
                    contentMode: image.contentMode,
                    symbol: "photo",
                    label: String(localized: "Image")
                )
            case .shape(let shape):
                CanvasShapeView(shape: shape)
            case .connector(let connector):
                CanvasConnectorView(connector: connector, elementFrame: element.frame)
            case .stickyNote(let sticky):
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(sticky.color.swiftUIColor)
                    Group {
                        if sticky.text.isEmpty {
                            Text("Sticky note")
                        } else {
                            Text(verbatim: sticky.text)
                        }
                    }
                    .font(.body)
                    .foregroundStyle(Color.primary)
                    .padding(10)
                }
            case .tape(let tape):
                CanvasTapeView(tape: tape)
            case .sticker(let sticker):
                assetView(
                    assetID: sticker.assetID,
                    contentMode: "fit",
                    symbol: "star.square",
                    label: sticker.accessibilityLabel ?? String(localized: "Sticker")
                )
            case .link(let link):
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: link.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(verbatim: link.destination.host ?? link.destination.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .opacity(element.opacity)
    }

    @ViewBuilder
    private func assetView(
        assetID: AssetID,
        contentMode: String,
        symbol: String,
        label: String
    ) -> some View {
        if let image = assetImageResolver(assetID, imageRequest),
           imageRequest.accepts(image) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode.lowercased() == "fill" ? .fill : .fit)
                .clipped()
                .accessibilityLabel(Text(verbatim: label))
        } else {
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(Text(verbatim: String.localizedStringWithFormat(
                String(localized: "%@ placeholder"),
                label
            )))
        }
    }
}

private struct CanvasShapeView: View {
    let shape: ShapeElement

    var body: some View {
        switch shape.shape.lowercased() {
        case "ellipse", "circle":
            ZStack {
                Ellipse().fill(shape.fillColor?.swiftUIColor ?? .clear)
                Ellipse().stroke(
                    shape.strokeColor.swiftUIColor,
                    lineWidth: CGFloat(shape.lineWidth)
                )
            }
        case "rectangle":
            ZStack {
                Rectangle().fill(shape.fillColor?.swiftUIColor ?? .clear)
                Rectangle().stroke(
                    shape.strokeColor.swiftUIColor,
                    lineWidth: CGFloat(shape.lineWidth)
                )
            }
        default:
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(shape.fillColor?.swiftUIColor ?? .clear)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        shape.strokeColor.swiftUIColor,
                        lineWidth: CGFloat(shape.lineWidth)
                    )
            }
        }
    }
}

private struct CanvasConnectorView: View {
    let connector: ConnectorElement
    let elementFrame: CanvasRect

    var body: some View {
        Canvas { context, size in
            let start = localPoint(connector.start, size: size)
            let end = localPoint(connector.end, size: size)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(
                path,
                with: .color(connector.strokeColor.swiftUIColor),
                lineWidth: CGFloat(connector.lineWidth)
            )

            if connector.endCap.lowercased().contains("arrow") {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let length = max(8, min(18, CGFloat(connector.lineWidth) * 4))
                var cap = Path()
                cap.move(to: end)
                cap.addLine(to: CGPoint(
                    x: end.x - length * cos(angle - .pi / 6),
                    y: end.y - length * sin(angle - .pi / 6)
                ))
                cap.move(to: end)
                cap.addLine(to: CGPoint(
                    x: end.x - length * cos(angle + .pi / 6),
                    y: end.y - length * sin(angle + .pi / 6)
                ))
                context.stroke(
                    cap,
                    with: .color(connector.strokeColor.swiftUIColor),
                    lineWidth: CGFloat(connector.lineWidth)
                )
            }
        }
    }

    private func localPoint(_ point: CanvasPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: (point.x - elementFrame.x) / elementFrame.width * Double(size.width),
            y: (point.y - elementFrame.y) / elementFrame.height * Double(size.height)
        )
    }
}

private struct CanvasTapeView: View {
    let tape: TapeElement

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tape.color.swiftUIColor)
            Image(systemName: tape.isRevealed ? "eye" : "eye.slash")
                .font(.headline)
                .foregroundStyle(Color.primary.opacity(tape.isRevealed ? 0.45 : 0.75))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct CanvasElementSelectionOverlay: View {
    let element: CanvasElement
    let showsHandles: Bool
    let coordinateSpaceName: String
    let onResizeChanged: (CanvasElementResizeHandle, DragGesture.Value) -> Void
    let onResizeEnded: (CanvasElementResizeHandle, DragGesture.Value) -> Void
    let onRotationChanged: (DragGesture.Value) -> Void
    let onRotationEnded: (DragGesture.Value) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .stroke(
                        element.isLocked ? Color.secondary : Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, dash: element.isLocked ? [5, 4] : [])
                    )
                    .allowsHitTesting(false)

                if element.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .padding(5)
                        .background(.regularMaterial, in: Circle())
                        .position(x: proxy.size.width, y: 0)
                        .accessibilityHidden(true)
                } else if showsHandles {
                    ForEach(CanvasElementResizeHandle.allCases, id: \.self) { handle in
                        CanvasElementHandle(symbol: handle.symbolName, label: "Resize")
                            .position(handle.localPosition(in: proxy.size))
                            .highPriorityGesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
                                    .onChanged { onResizeChanged(handle, $0) }
                                    .onEnded { onResizeEnded(handle, $0) }
                            )
                            .accessibilityIdentifier("canvas.element.resize.\(handle.rawValue)")
                    }

                    CanvasElementHandle(symbol: "rotate.right", label: "Rotate")
                        .position(x: proxy.size.width / 2, y: 0)
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
                                .onChanged(onRotationChanged)
                                .onEnded(onRotationEnded)
                        )
                        .accessibilityIdentifier("canvas.element.rotate")
                }
            }
        }
    }
}

private struct CanvasElementHandle: View {
    let symbol: String
    let label: LocalizedStringKey

    var body: some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: Circle())
            .overlay {
                Circle().stroke(Color.accentColor, lineWidth: 1.5)
            }
            .contentShape(Circle())
            .hoverEffect(.lift)
            .accessibilityLabel(Text(label))
    }
}

// MARK: - Editing sheet

private struct CanvasElementEditorTarget: Identifiable {
    let id: ElementID
}

private struct CanvasElementEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let element: CanvasElement
    let onSave: (CanvasElementContent) -> Void

    @State private var text: String
    @State private var linkTitle: String
    @State private var linkDestination: String
    @State private var tapeIsRevealed: Bool

    init(element: CanvasElement, onSave: @escaping (CanvasElementContent) -> Void) {
        self.element = element
        self.onSave = onSave

        switch element.content {
        case .text(let textElement):
            _text = State(initialValue: textElement.text)
        case .stickyNote(let sticky):
            _text = State(initialValue: sticky.text)
        default:
            _text = State(initialValue: "")
        }

        if case .link(let link) = element.content {
            _linkTitle = State(initialValue: link.title)
            _linkDestination = State(initialValue: link.destination.absoluteString)
        } else {
            _linkTitle = State(initialValue: "")
            _linkDestination = State(initialValue: "")
        }

        if case .tape(let tape) = element.content {
            _tapeIsRevealed = State(initialValue: tape.isRevealed)
        } else {
            _tapeIsRevealed = State(initialValue: false)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                editorFields
            }
            .navigationTitle(Text(verbatim: CanvasElementPresentationModel(element: element).title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        guard let content = editedContent else { return }
                        onSave(content)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editedContent == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("canvas.element.editor")
    }

    @ViewBuilder
    private var editorFields: some View {
        switch element.content {
        case .text, .stickyNote:
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 180)
                    .accessibilityLabel(Text("Text"))
                    .accessibilityIdentifier("canvas.element.editor.text")
            } header: {
                Text("Text")
            }
        case .link:
            Section {
                TextField(text: $linkTitle, prompt: nil, axis: .horizontal) {
                    Text("Title")
                }
                .accessibilityIdentifier("canvas.element.editor.link-title")
                TextField(text: $linkDestination, prompt: nil, axis: .horizontal) {
                    Text("Address")
                }
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .accessibilityIdentifier("canvas.element.editor.link-address")
            } header: {
                Text("Link")
            }
        case .tape:
            Section {
                Toggle(isOn: $tapeIsRevealed) {
                    Text("Reveal tape")
                }
                .accessibilityIdentifier("canvas.element.editor.tape-reveal")
            }
        default:
            Section {
                Text("This element has no editable text.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var editedContent: CanvasElementContent? {
        switch element.content {
        case .text(var value):
            value.text = text
            return .text(value)
        case .stickyNote(var value):
            value.text = text
            return .stickyNote(value)
        case .link:
            let trimmedAddress = linkDestination.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let destination = URL(string: trimmedAddress), destination.scheme != nil else {
                return nil
            }
            let trimmedTitle = linkTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return .link(LinkElement(
                title: trimmedTitle.isEmpty ? destination.absoluteString : trimmedTitle,
                destination: destination
            ))
        case .tape(var value):
            value.isRevealed = tapeIsRevealed
            return .tape(value)
        default:
            return nil
        }
    }
}

private extension CanvasElementContent {
    var isInlineEditable: Bool {
        switch self {
        case .text, .stickyNote, .link, .tape: true
        default: false
        }
    }

    var prefersAspectPreservingResize: Bool {
        switch self {
        case .image, .sticker: true
        default: false
        }
    }
}

private extension RGBAColor {
    var swiftUIColor: Color {
        Color(
            red: safeColorComponent(red, fallback: 0),
            green: safeColorComponent(green, fallback: 0),
            blue: safeColorComponent(blue, fallback: 0),
            opacity: safeColorComponent(alpha, fallback: 1)
        )
    }

    private func safeColorComponent(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, 0), 1)
    }
}

private extension View {
    @ViewBuilder
    func canvasElementEditAccessibilityAction(
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if isEnabled {
            accessibilityAction(named: Text("Edit"), action)
        } else {
            self
        }
    }
}
