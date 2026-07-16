import Foundation
import NotesCore

/// Deterministic, ID-addressed editing operations for a page's structured canvas elements.
///
/// Connector endpoints are page-space coordinates. Translation moves both endpoints by the
/// element's actual (post-containment) displacement. Resizing maps the endpoints affinely from
/// the old frame into the new frame. Rotation is stored on the element and does not rewrite the
/// connector's page-space endpoints. Containment applies to the unrotated frame, so rotated
/// corners may extend beyond the page while the element's interactive frame remains reachable.
enum CanvasElementEditing {
    static let minimumInteractiveLength = 44.0

    private static let maximumDimension = 1_000_000_000.0
    private static let maximumCoordinateMagnitude = 1_000_000_000_000.0
    private static let defaultDuplicateOffset = CanvasPoint(x: 16, y: 16)

    // MARK: - Original creation defaults

    static func makeText(
        id: ElementID,
        text: String = "",
        at origin: CanvasPoint,
        within pageBounds: CanvasRect,
        now: Date
    ) -> CanvasElement {
        makeElement(
            id: id,
            frame: CanvasRect(x: origin.x, y: origin.y, width: 240, height: 96),
            content: .text(
                TextElement(
                    text: text,
                    fontName: "System",
                    fontSize: 22,
                    color: RGBAColor(red: 0.09, green: 0.10, blue: 0.12)
                )
            ),
            within: pageBounds,
            now: now
        )
    }

    static func makeShape(
        id: ElementID,
        shape: String = "roundedRectangle",
        at origin: CanvasPoint,
        within pageBounds: CanvasRect,
        now: Date
    ) -> CanvasElement {
        let accent = RGBAColor(red: 0.18, green: 0.42, blue: 0.88)
        return makeElement(
            id: id,
            frame: CanvasRect(x: origin.x, y: origin.y, width: 180, height: 120),
            content: .shape(
                ShapeElement(
                    shape: shape,
                    strokeColor: accent,
                    fillColor: RGBAColor(red: 0.18, green: 0.42, blue: 0.88, alpha: 0.12),
                    lineWidth: 3
                )
            ),
            within: pageBounds,
            now: now
        )
    }

    static func makeStickyNote(
        id: ElementID,
        text: String = "",
        at origin: CanvasPoint,
        within pageBounds: CanvasRect,
        now: Date
    ) -> CanvasElement {
        makeElement(
            id: id,
            frame: CanvasRect(x: origin.x, y: origin.y, width: 180, height: 180),
            content: .stickyNote(
                StickyNoteElement(
                    text: text,
                    color: RGBAColor(red: 1, green: 0.91, blue: 0.48)
                )
            ),
            within: pageBounds,
            now: now
        )
    }

    static func makeTape(
        id: ElementID,
        at origin: CanvasPoint,
        within pageBounds: CanvasRect,
        now: Date
    ) -> CanvasElement {
        makeElement(
            id: id,
            frame: CanvasRect(x: origin.x, y: origin.y, width: 220, height: 56),
            content: .tape(
                TapeElement(
                    color: RGBAColor(red: 0.75, green: 0.68, blue: 0.96, alpha: 0.82),
                    isRevealed: false
                )
            ),
            within: pageBounds,
            now: now
        )
    }

    static func makeLink(
        id: ElementID,
        title: String,
        destination: URL,
        at origin: CanvasPoint,
        within pageBounds: CanvasRect,
        now: Date
    ) -> CanvasElement {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return makeElement(
            id: id,
            frame: CanvasRect(x: origin.x, y: origin.y, width: 260, height: 72),
            content: .link(
                LinkElement(
                    title: normalizedTitle.isEmpty ? "Link" : normalizedTitle,
                    destination: destination
                )
            ),
            within: pageBounds,
            now: now
        )
    }

    // MARK: - Collection lifecycle

    /// Produces a canonical stack ordered back-to-front with contiguous, overflow-safe z-indices.
    static func normalized(
        _ elements: [CanvasElement],
        within pageBounds: CanvasRect,
        now: Date
    ) -> [CanvasElement] {
        let canonical = elements.enumerated().map { offset, element in
            (offset: offset, element: canonicalized(element, within: pageBounds, now: now))
        }
        let ordered = canonical.sorted { lhs, rhs in
            if lhs.element.zIndex != rhs.element.zIndex {
                return lhs.element.zIndex < rhs.element.zIndex
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return renormalizingZIndices(ordered, now: now)
    }

    static func inserting(
        _ element: CanvasElement,
        after anchorID: ElementID? = nil,
        in elements: [CanvasElement],
        within pageBounds: CanvasRect,
        now: Date
    ) -> [CanvasElement] {
        guard !elements.contains(where: { $0.id == element.id }) else { return elements }
        if let anchorID, uniquelyMatchedElement(anchorID, in: elements) == nil {
            return elements
        }

        var stack = normalized(elements, within: pageBounds, now: now)
        var inserted = canonicalized(element, within: pageBounds, now: now)
        inserted = touching(inserted, now: now)

        if let anchorID, let anchorIndex = stack.firstIndex(where: { $0.id == anchorID }) {
            stack.insert(inserted, at: anchorIndex + 1)
        } else {
            stack.append(inserted)
        }
        return renormalizingZIndices(stack, now: now)
    }

    static func deleting(
        _ id: ElementID,
        from elements: [CanvasElement],
        within pageBounds: CanvasRect,
        now: Date
    ) -> [CanvasElement] {
        guard let rawElement = uniquelyMatchedElement(id, in: elements), !rawElement.isLocked else {
            return elements
        }

        var stack = normalized(elements, within: pageBounds, now: now)
        stack.removeAll(where: { $0.id == id })
        return renormalizingZIndices(stack, now: now)
    }

    static func duplicating(
        _ id: ElementID,
        as newID: ElementID,
        offset: CanvasPoint = CanvasPoint(x: 16, y: 16),
        in elements: [CanvasElement],
        within pageBounds: CanvasRect,
        now: Date
    ) -> [CanvasElement] {
        guard id != newID,
              !elements.contains(where: { $0.id == newID }),
              let rawSource = uniquelyMatchedElement(id, in: elements),
              !rawSource.isLocked else {
            return elements
        }

        var stack = normalized(elements, within: pageBounds, now: now)
        guard let sourceIndex = stack.firstIndex(where: { $0.id == id }) else { return elements }
        let source = stack[sourceIndex]
        let safeOffset = CanvasPoint(
            x: finiteCoordinate(offset.x, fallback: defaultDuplicateOffset.x),
            y: finiteCoordinate(offset.y, fallback: defaultDuplicateOffset.y)
        )
        let proposedFrame = CanvasRect(
            x: adding(source.frame.x, safeOffset.x),
            y: adding(source.frame.y, safeOffset.y),
            width: source.frame.width,
            height: source.frame.height
        )
        let duplicateFrame = canonicalFrame(proposedFrame, within: pageBounds)
        let actualOffset = CanvasPoint(
            x: duplicateFrame.x - source.frame.x,
            y: duplicateFrame.y - source.frame.y
        )
        let creationDate = later(validDate(now, fallback: source.modifiedAt), source.modifiedAt)
        var duplicate = source
        duplicate.id = newID
        duplicate.frame = duplicateFrame
        duplicate.content = translatingConnector(source.content, by: actualOffset, in: duplicateFrame)
        duplicate.isLocked = false
        duplicate.createdAt = creationDate
        duplicate.modifiedAt = creationDate
        stack.insert(duplicate, at: sourceIndex + 1)
        return renormalizingZIndices(stack, now: now)
    }

    static func updatingContent(
        of id: ElementID,
        to content: CanvasElementContent,
        in elements: [CanvasElement],
        within pageBounds: CanvasRect,
        now: Date
    ) -> [CanvasElement] {
        guard let rawElement = uniquelyMatchedElement(id, in: elements), !rawElement.isLocked else {
            return elements
        }

        var stack = normalized(elements, within: pageBounds, now: now)
        guard let index = stack.firstIndex(where: { $0.id == id }) else { return elements }
        let canonicalContent = normalizedContent(content, in: stack[index].frame)
        guard canonicalContent != stack[index].content else { return stack }
        stack[index].content = canonicalContent
        stack[index] = touching(stack[index], now: now)
        return stack
    }

    // MARK: - Geometry

    static func translating(
        _ selectedIDs: Set<ElementID>,
        by offset: CanvasPoint,
        in elements: [CanvasElement],
        within pageBounds: CanvasRect,
        now: Date
    ) -> [CanvasElement] {
        guard selectedIDsAreUnambiguous(selectedIDs, in: elements),
              elements.contains(where: { selectedIDs.contains($0.id) && !$0.isLocked }) else {
            return elements
        }

        let safeOffset = CanvasPoint(
            x: finiteCoordinate(offset.x, fallback: 0),
            y: finiteCoordinate(offset.y, fallback: 0)
        )
        var stack = normalized(elements, within: pageBounds, now: now)
        for index in stack.indices where selectedIDs.contains(stack[index].id) && !stack[index].isLocked {
            let oldFrame = stack[index].frame
            let proposed = CanvasRect(
                x: adding(oldFrame.x, safeOffset.x),
                y: adding(oldFrame.y, safeOffset.y),
                width: oldFrame.width,
                height: oldFrame.height
            )
            let newFrame = canonicalFrame(proposed, within: pageBounds)
            let actualOffset = CanvasPoint(x: newFrame.x - oldFrame.x, y: newFrame.y - oldFrame.y)
            let newContent = translatingConnector(stack[index].content, by: actualOffset, in: newFrame)
            guard newFrame != oldFrame || newContent != stack[index].content else { continue }
            stack[index].frame = newFrame
            stack[index].content = newContent
            stack[index] = touching(stack[index], now: now)
        }
        return stack
    }

    /// Resizes one element to a proposed frame. A negative dimension represents a crossed resize
    /// handle and keeps that axis's maximum edge fixed. When preserving aspect ratio, the
    /// dimension with the larger relative change drives a uniform scale from the current size.
    static func resizing(
        _ id: ElementID,
        to proposedFrame: CanvasRect,
        preservingAspectRatio: Bool,
        in elements: [CanvasElement],
        within pageBounds: CanvasRect,
        now: Date
    ) -> [CanvasElement] {
        guard let rawElement = uniquelyMatchedElement(id, in: elements), !rawElement.isLocked else {
            return elements
        }

        var stack = normalized(elements, within: pageBounds, now: now)
        guard let index = stack.firstIndex(where: { $0.id == id }) else { return elements }
        let oldFrame = stack[index].frame
        let widthWasNegative = proposedFrame.width.isFinite && proposedFrame.width < 0
        let heightWasNegative = proposedFrame.height.isFinite && proposedFrame.height < 0
        var target = canonicalUncontainedFrame(proposedFrame)
        let fixedMaximumX = adding(target.x, target.width)
        let fixedMaximumY = adding(target.y, target.height)
        if preservingAspectRatio {
            let widthScale = target.width / oldFrame.width
            let heightScale = target.height / oldFrame.height
            let widthChange = abs(widthScale - 1)
            let heightChange = abs(heightScale - 1)
            let proposedScale = widthChange >= heightChange ? widthScale : heightScale
            let minimumScale = max(
                minimumInteractiveLength / oldFrame.width,
                minimumInteractiveLength / oldFrame.height
            )
            let maximumScale = min(
                maximumDimension / oldFrame.width,
                maximumDimension / oldFrame.height
            )
            let scale = clamped(proposedScale, minimum: minimumScale, maximum: maximumScale)
            target.width = oldFrame.width * scale
            target.height = oldFrame.height * scale
            if widthWasNegative {
                target.x = adding(fixedMaximumX, -target.width)
            }
            if heightWasNegative {
                target.y = adding(fixedMaximumY, -target.height)
            }
        }
        target = containing(target, within: canonicalPageBounds(pageBounds))

        let newContent = resizingConnector(stack[index].content, from: oldFrame, to: target)
        guard target != oldFrame || newContent != stack[index].content else { return stack }
        stack[index].frame = target
        stack[index].content = newContent
        stack[index] = touching(stack[index], now: now)
        return stack
    }

    static func rotating(
        _ selectedIDs: Set<ElementID>,
        by radians: Double,
        in elements: [CanvasElement],
        within pageBounds: CanvasRect,
        now: Date
    ) -> [CanvasElement] {
        guard selectedIDsAreUnambiguous(selectedIDs, in: elements),
              elements.contains(where: { selectedIDs.contains($0.id) && !$0.isLocked }) else {
            return elements
        }

        let delta = normalizedAngle(radians)
        var stack = normalized(elements, within: pageBounds, now: now)
        for index in stack.indices where selectedIDs.contains(stack[index].id) && !stack[index].isLocked {
            let rotation = normalizedAngle(normalizedAngle(stack[index].rotationRadians) + delta)
            guard rotation != stack[index].rotationRadians else { continue }
            stack[index].rotationRadians = rotation
            stack[index] = touching(stack[index], now: now)
        }
        return stack
    }

    // MARK: - Properties and stacking

    static func settingLocked(
        _ isLocked: Bool,
        for selectedIDs: Set<ElementID>,
        in elements: [CanvasElement],
        within pageBounds: CanvasRect,
        now: Date
    ) -> [CanvasElement] {
        guard selectedIDsAreUnambiguous(selectedIDs, in: elements),
              elements.contains(where: {
                  selectedIDs.contains($0.id) && $0.isLocked != isLocked
              }) else {
            return elements
        }
        var stack = normalized(elements, within: pageBounds, now: now)
        for index in stack.indices where selectedIDs.contains(stack[index].id) {
            guard stack[index].isLocked != isLocked else { continue }
            stack[index].isLocked = isLocked
            stack[index] = touching(stack[index], now: now)
        }
        return stack
    }

    static func settingOpacity(
        _ opacity: Double,
        for selectedIDs: Set<ElementID>,
        in elements: [CanvasElement],
        within pageBounds: CanvasRect,
        now: Date
    ) -> [CanvasElement] {
        guard selectedIDsAreUnambiguous(selectedIDs, in: elements),
              elements.contains(where: { selectedIDs.contains($0.id) && !$0.isLocked }) else {
            return elements
        }

        var stack = normalized(elements, within: pageBounds, now: now)
        for index in stack.indices where selectedIDs.contains(stack[index].id) && !stack[index].isLocked {
            let normalizedOpacity = finiteUnitInterval(opacity, fallback: stack[index].opacity)
            guard normalizedOpacity != stack[index].opacity else { continue }
            stack[index].opacity = normalizedOpacity
            stack[index] = touching(stack[index], now: now)
        }
        return stack
    }

    static func bringingToFront(
        _ selectedIDs: Set<ElementID>,
        in elements: [CanvasElement],
        within pageBounds: CanvasRect,
        now: Date
    ) -> [CanvasElement] {
        guard selectedIDsAreUnambiguous(selectedIDs, in: elements),
              elements.contains(where: { selectedIDs.contains($0.id) && !$0.isLocked }) else {
            return elements
        }
        let stack = normalized(elements, within: pageBounds, now: now)
        let movableIDs = Set(stack.lazy.filter { selectedIDs.contains($0.id) && !$0.isLocked }.map(\.id))
        let reordered = stack.filter { !movableIDs.contains($0.id) }
            + stack.filter { movableIDs.contains($0.id) }
        return renormalizingZIndices(reordered, now: now)
    }

    static func sendingToBack(
        _ selectedIDs: Set<ElementID>,
        in elements: [CanvasElement],
        within pageBounds: CanvasRect,
        now: Date
    ) -> [CanvasElement] {
        guard selectedIDsAreUnambiguous(selectedIDs, in: elements),
              elements.contains(where: { selectedIDs.contains($0.id) && !$0.isLocked }) else {
            return elements
        }
        let stack = normalized(elements, within: pageBounds, now: now)
        let movableIDs = Set(stack.lazy.filter { selectedIDs.contains($0.id) && !$0.isLocked }.map(\.id))
        let reordered = stack.filter { movableIDs.contains($0.id) }
            + stack.filter { !movableIDs.contains($0.id) }
        return renormalizingZIndices(reordered, now: now)
    }

    // MARK: - Canonicalization

    /// Refuses identity-ambiguous edits rather than guessing which duplicate persisted ID was
    /// selected. The repository also rejects duplicate IDs, but this keeps corrupt/imported data
    /// from turning a single-element gesture into a multi-element mutation before the next save.
    private static func uniquelyMatchedElement(
        _ id: ElementID,
        in elements: [CanvasElement]
    ) -> CanvasElement? {
        var match: CanvasElement?
        for element in elements where element.id == id {
            guard match == nil else { return nil }
            match = element
        }
        return match
    }

    private static func selectedIDsAreUnambiguous(
        _ selectedIDs: Set<ElementID>,
        in elements: [CanvasElement]
    ) -> Bool {
        var matchedIDs = Set<ElementID>()
        for element in elements where selectedIDs.contains(element.id) {
            guard matchedIDs.insert(element.id).inserted else { return false }
        }
        return true
    }

    private static func makeElement(
        id: ElementID,
        frame: CanvasRect,
        content: CanvasElementContent,
        within pageBounds: CanvasRect,
        now: Date
    ) -> CanvasElement {
        let timestamp = validDate(now, fallback: Date(timeIntervalSinceReferenceDate: 0))
        let element = CanvasElement(
            id: id,
            frame: frame,
            content: content,
            createdAt: timestamp,
            modifiedAt: timestamp
        )
        return canonicalized(element, within: pageBounds, now: timestamp)
    }

    private static func canonicalized(
        _ element: CanvasElement,
        within pageBounds: CanvasRect,
        now: Date
    ) -> CanvasElement {
        let original = element
        var result = element
        result.createdAt = validDate(element.createdAt, fallback: validDate(now, fallback: Date(timeIntervalSinceReferenceDate: 0)))
        result.modifiedAt = validDate(element.modifiedAt, fallback: result.createdAt)
        if result.modifiedAt < result.createdAt {
            result.modifiedAt = result.createdAt
        }

        let uncontainedFrame = canonicalUncontainedFrame(element.frame)
        let frame = containing(uncontainedFrame, within: canonicalPageBounds(pageBounds))
        let containmentOffset = CanvasPoint(
            x: frame.x - uncontainedFrame.x,
            y: frame.y - uncontainedFrame.y
        )
        result.frame = frame
        result.rotationRadians = normalizedAngle(element.rotationRadians)
        result.opacity = finiteUnitInterval(element.opacity, fallback: 1)
        result.content = normalizedContent(element.content, in: uncontainedFrame)
        result.content = translatingConnector(result.content, by: containmentOffset, in: frame)

        if result != original {
            result = touching(result, now: now)
        }
        return result
    }

    private static func canonicalUncontainedFrame(_ frame: CanvasRect) -> CanvasRect {
        var x = finiteCoordinate(frame.x, fallback: 0)
        var y = finiteCoordinate(frame.y, fallback: 0)

        let rawWidth = finiteCoordinate(frame.width, fallback: minimumInteractiveLength)
        let rawHeight = finiteCoordinate(frame.height, fallback: minimumInteractiveLength)
        let width = normalizedDimension(rawWidth)
        let height = normalizedDimension(rawHeight)
        if rawWidth < 0 {
            x = adding(x, -width)
        }
        if rawHeight < 0 {
            y = adding(y, -height)
        }

        return CanvasRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
    }

    private static func canonicalFrame(_ frame: CanvasRect, within pageBounds: CanvasRect) -> CanvasRect {
        containing(canonicalUncontainedFrame(frame), within: canonicalPageBounds(pageBounds))
    }

    private static func canonicalPageBounds(_ bounds: CanvasRect) -> CanvasRect {
        var x = finiteCoordinate(bounds.x, fallback: 0)
        var y = finiteCoordinate(bounds.y, fallback: 0)
        let rawWidth = finiteCoordinate(bounds.width, fallback: minimumInteractiveLength)
        let rawHeight = finiteCoordinate(bounds.height, fallback: minimumInteractiveLength)
        let width = max(min(abs(rawWidth), maximumDimension), Double.leastNonzeroMagnitude)
        let height = max(min(abs(rawHeight), maximumDimension), Double.leastNonzeroMagnitude)
        if rawWidth < 0 {
            x = adding(x, -width)
        }
        if rawHeight < 0 {
            y = adding(y, -height)
        }
        x = clamped(
            x,
            minimum: -maximumCoordinateMagnitude,
            maximum: maximumCoordinateMagnitude - width
        )
        y = clamped(
            y,
            minimum: -maximumCoordinateMagnitude,
            maximum: maximumCoordinateMagnitude - height
        )
        return CanvasRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
    }

    private static func containing(_ frame: CanvasRect, within bounds: CanvasRect) -> CanvasRect {
        var result = frame
        result.x = containedOrigin(
            frameOrigin: frame.x,
            frameLength: frame.width,
            boundsOrigin: bounds.x,
            boundsLength: bounds.width
        )
        result.y = containedOrigin(
            frameOrigin: frame.y,
            frameLength: frame.height,
            boundsOrigin: bounds.y,
            boundsLength: bounds.height
        )
        return result
    }

    private static func containedOrigin(
        frameOrigin: Double,
        frameLength: Double,
        boundsOrigin: Double,
        boundsLength: Double
    ) -> Double {
        let boundsEnd = adding(boundsOrigin, boundsLength)
        if frameLength <= boundsLength {
            return clamped(frameOrigin, minimum: boundsOrigin, maximum: boundsEnd - frameLength)
        }

        let visibleLength = min(minimumInteractiveLength, boundsLength)
        let minimumOrigin = adding(adding(boundsOrigin, visibleLength), -frameLength)
        let maximumOrigin = boundsEnd - visibleLength
        return clamped(frameOrigin, minimum: minimumOrigin, maximum: maximumOrigin)
    }

    private static func normalizedContent(
        _ content: CanvasElementContent,
        in frame: CanvasRect
    ) -> CanvasElementContent {
        switch content {
        case .text(var text):
            if text.fontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text.fontName = "System"
            }
            text.fontSize = finiteClamped(text.fontSize, fallback: 17, minimum: 1, maximum: 512)
            text.color = normalizedColor(text.color)
            return .text(text)
        case .image(var image):
            if image.contentMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                image.contentMode = "fit"
            }
            return .image(image)
        case .shape(var shape):
            if shape.shape.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                shape.shape = "rectangle"
            }
            shape.strokeColor = normalizedColor(shape.strokeColor)
            shape.fillColor = shape.fillColor.map(normalizedColor)
            shape.lineWidth = finiteClamped(shape.lineWidth, fallback: 2, minimum: 0.5, maximum: 256)
            return .shape(shape)
        case .connector(var connector):
            let middleY = adding(frame.y, frame.height / 2)
            connector.start = normalizedPoint(
                connector.start,
                fallback: CanvasPoint(x: frame.x, y: middleY)
            )
            connector.end = normalizedPoint(
                connector.end,
                fallback: CanvasPoint(x: adding(frame.x, frame.width), y: middleY)
            )
            connector.strokeColor = normalizedColor(connector.strokeColor)
            connector.lineWidth = finiteClamped(connector.lineWidth, fallback: 2, minimum: 0.5, maximum: 256)
            if connector.endCap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                connector.endCap = "arrow"
            }
            return .connector(connector)
        case .stickyNote(var stickyNote):
            stickyNote.color = normalizedColor(stickyNote.color)
            return .stickyNote(stickyNote)
        case .tape(var tape):
            tape.color = normalizedColor(tape.color)
            return .tape(tape)
        case .sticker, .link:
            return content
        }
    }

    private static func translatingConnector(
        _ content: CanvasElementContent,
        by offset: CanvasPoint,
        in frame: CanvasRect
    ) -> CanvasElementContent {
        let normalized = normalizedContent(content, in: frame)
        guard case .connector(var connector) = normalized else {
            return normalized
        }
        connector.start = CanvasPoint(
            x: adding(connector.start.x, offset.x),
            y: adding(connector.start.y, offset.y)
        )
        connector.end = CanvasPoint(
            x: adding(connector.end.x, offset.x),
            y: adding(connector.end.y, offset.y)
        )
        return .connector(connector)
    }

    private static func resizingConnector(
        _ content: CanvasElementContent,
        from oldFrame: CanvasRect,
        to newFrame: CanvasRect
    ) -> CanvasElementContent {
        let normalized = normalizedContent(content, in: oldFrame)
        guard case .connector(var connector) = normalized else {
            return normalized
        }
        connector.start = mapping(connector.start, from: oldFrame, to: newFrame)
        connector.end = mapping(connector.end, from: oldFrame, to: newFrame)
        return .connector(connector)
    }

    private static func mapping(
        _ point: CanvasPoint,
        from oldFrame: CanvasRect,
        to newFrame: CanvasRect
    ) -> CanvasPoint {
        let relativeX = (point.x - oldFrame.x) / oldFrame.width
        let relativeY = (point.y - oldFrame.y) / oldFrame.height
        return CanvasPoint(
            x: adding(newFrame.x, multiplied(relativeX, newFrame.width)),
            y: adding(newFrame.y, multiplied(relativeY, newFrame.height))
        )
    }

    private static func renormalizingZIndices(
        _ elements: [CanvasElement],
        now: Date
    ) -> [CanvasElement] {
        elements.enumerated().map { offset, element in
            guard element.zIndex != offset else { return element }
            var updated = element
            updated.zIndex = offset
            return touching(updated, now: now)
        }
    }

    private static func touching(_ element: CanvasElement, now: Date) -> CanvasElement {
        var result = element
        result.createdAt = validDate(
            result.createdAt,
            fallback: Date(timeIntervalSinceReferenceDate: 0)
        )
        let previous = validDate(result.modifiedAt, fallback: result.createdAt)
        let safeNow = validDate(now, fallback: previous)
        result.modifiedAt = later(later(previous, result.createdAt), safeNow)
        return result
    }

    private static func normalizedAngle(_ radians: Double) -> Double {
        guard radians.isFinite else { return 0 }
        let fullTurn = 2 * Double.pi
        var result = radians.truncatingRemainder(dividingBy: fullTurn)
        if result >= Double.pi {
            result -= fullTurn
        } else if result < -Double.pi {
            result += fullTurn
        }
        return result == -0 ? 0 : result
    }

    private static func normalizedDimension(_ value: Double) -> Double {
        let magnitude = abs(value)
        return finiteClamped(
            magnitude,
            fallback: minimumInteractiveLength,
            minimum: minimumInteractiveLength,
            maximum: maximumDimension
        )
    }

    private static func normalizedColor(_ color: RGBAColor) -> RGBAColor {
        RGBAColor(
            red: finiteUnitInterval(color.red, fallback: 0),
            green: finiteUnitInterval(color.green, fallback: 0),
            blue: finiteUnitInterval(color.blue, fallback: 0),
            alpha: finiteUnitInterval(color.alpha, fallback: 1)
        )
    }

    private static func normalizedPoint(_ point: CanvasPoint, fallback: CanvasPoint) -> CanvasPoint {
        CanvasPoint(
            x: finiteCoordinate(point.x, fallback: fallback.x),
            y: finiteCoordinate(point.y, fallback: fallback.y)
        )
    }

    private static func finiteCoordinate(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return clamped(
            value,
            minimum: -maximumCoordinateMagnitude,
            maximum: maximumCoordinateMagnitude
        )
    }

    private static func finiteUnitInterval(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return clamped(value, minimum: 0, maximum: 1)
    }

    private static func finiteClamped(
        _ value: Double,
        fallback: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return clamped(value, minimum: minimum, maximum: maximum)
    }

    private static func clamped(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    private static func adding(_ lhs: Double, _ rhs: Double) -> Double {
        let result = lhs + rhs
        if result.isFinite {
            return finiteCoordinate(result, fallback: 0)
        }
        return rhs.sign == .minus ? -maximumCoordinateMagnitude : maximumCoordinateMagnitude
    }

    private static func multiplied(_ lhs: Double, _ rhs: Double) -> Double {
        let result = lhs * rhs
        if result.isFinite {
            return finiteCoordinate(result, fallback: 0)
        }
        return lhs.sign == rhs.sign ? maximumCoordinateMagnitude : -maximumCoordinateMagnitude
    }

    private static func validDate(_ date: Date, fallback: Date) -> Date {
        date.timeIntervalSinceReferenceDate.isFinite ? date : fallback
    }

    private static func later(_ lhs: Date, _ rhs: Date) -> Date {
        lhs >= rhs ? lhs : rhs
    }
}
