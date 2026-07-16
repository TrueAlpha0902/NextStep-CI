import Foundation
import NotesCore
@testable import NotesApp
import XCTest

final class CanvasElementEditingTests: XCTestCase {
    private let pageBounds = CanvasRect(x: 0, y: 0, width: 500, height: 500)

    func testIDBasedLifecycleStillTargetsCorrectElementAfterReordering() throws {
        let timestamp = Date(timeIntervalSince1970: 100)
        let editedAt = Date(timeIntervalSince1970: 200)
        let firstID = elementID(1)
        let secondID = elementID(2)
        let thirdID = elementID(3)
        let duplicateID = elementID(4)
        let input = [
            makeText(id: secondID, text: "Second", zIndex: 0, timestamp: timestamp),
            makeText(id: firstID, text: "First", zIndex: -10, timestamp: timestamp),
            makeText(id: thirdID, text: "Third", zIndex: 10, timestamp: timestamp),
        ]

        let reordered = CanvasElementEditing.bringingToFront(
            Set([firstID]),
            in: input,
            within: pageBounds,
            now: editedAt
        )
        XCTAssertEqual(reordered.map(\.id), [secondID, thirdID, firstID])

        let replacement = CanvasElementContent.text(TextElement(text: "Edited third"))
        let edited = CanvasElementEditing.updatingContent(
            of: thirdID,
            to: replacement,
            in: reordered,
            within: pageBounds,
            now: editedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(text(in: try element(thirdID, from: edited)), "Edited third")
        XCTAssertEqual(text(in: try element(firstID, from: edited)), "First")

        let duplicated = CanvasElementEditing.duplicating(
            thirdID,
            as: duplicateID,
            offset: CanvasPoint(x: 12, y: 8),
            in: edited,
            within: pageBounds,
            now: editedAt.addingTimeInterval(2)
        )
        XCTAssertEqual(duplicated.map(\.id), [secondID, thirdID, duplicateID, firstID])
        XCTAssertEqual(text(in: try element(duplicateID, from: duplicated)), "Edited third")
        XCTAssertEqual(try element(duplicateID, from: duplicated).frame.x,
                       try element(thirdID, from: duplicated).frame.x + 12)
        XCTAssertEqual(try element(duplicateID, from: duplicated).createdAt,
                       editedAt.addingTimeInterval(2))
        XCTAssertEqual(try element(duplicateID, from: duplicated).modifiedAt,
                       editedAt.addingTimeInterval(2))

        let deleted = CanvasElementEditing.deleting(
            secondID,
            from: duplicated,
            within: pageBounds,
            now: editedAt.addingTimeInterval(3)
        )
        XCTAssertEqual(deleted.map(\.id), [thirdID, duplicateID, firstID])
        XCTAssertEqual(deleted.map(\.zIndex), [0, 1, 2])
    }

    func testInsertionIsStableAndRejectsDuplicateIDOrMissingAnchor() {
        let now = Date(timeIntervalSince1970: 100)
        let first = makeText(id: elementID(1), text: "First", zIndex: 0, timestamp: now)
        let second = makeText(id: elementID(2), text: "Second", zIndex: 1, timestamp: now)

        let inserted = CanvasElementEditing.inserting(
            second,
            after: first.id,
            in: [first],
            within: pageBounds,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(inserted.map(\.id), [first.id, second.id])
        XCTAssertEqual(inserted.map(\.zIndex), [0, 1])
        XCTAssertEqual(inserted[1].modifiedAt, now.addingTimeInterval(1))

        let duplicate = CanvasElementEditing.inserting(
            second,
            in: inserted,
            within: pageBounds,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(duplicate, inserted)

        let missingAnchor = CanvasElementEditing.inserting(
            makeText(id: elementID(3), text: "Third", zIndex: 2, timestamp: now),
            after: elementID(99),
            in: inserted,
            within: pageBounds,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(missingAnchor, inserted)
    }

    func testLockedElementRejectsEveryContentGeometryAndStackMutation() {
        let now = Date(timeIntervalSince1970: 100)
        let lockedID = elementID(1)
        var locked = makeText(
            id: lockedID,
            text: "Locked",
            zIndex: 0,
            isLocked: true,
            timestamp: now
        )
        locked.frame = CanvasRect(x: 900, y: -300, width: 20, height: 10)
        locked.rotationRadians = 5 * Double.pi
        locked.zIndex = .max
        locked.opacity = 2
        let other = makeText(id: elementID(2), text: "Other", zIndex: .min, timestamp: now)
        let input = [locked, other]
        let selected = Set([lockedID])
        let later = now.addingTimeInterval(10)

        XCTAssertEqual(
            CanvasElementEditing.translating(
                selected,
                by: CanvasPoint(x: 50, y: 50),
                in: input,
                within: pageBounds,
                now: later
            ),
            input
        )
        XCTAssertEqual(
            CanvasElementEditing.resizing(
                lockedID,
                to: CanvasRect(x: 10, y: 10, width: 300, height: 300),
                preservingAspectRatio: false,
                in: input,
                within: pageBounds,
                now: later
            ),
            input
        )
        XCTAssertEqual(
            CanvasElementEditing.rotating(
                selected,
                by: .pi,
                in: input,
                within: pageBounds,
                now: later
            ),
            input
        )
        XCTAssertEqual(
            CanvasElementEditing.settingOpacity(
                0.25,
                for: selected,
                in: input,
                within: pageBounds,
                now: later
            ),
            input
        )
        XCTAssertEqual(
            CanvasElementEditing.updatingContent(
                of: lockedID,
                to: .text(TextElement(text: "Changed")),
                in: input,
                within: pageBounds,
                now: later
            ),
            input
        )
        XCTAssertEqual(
            CanvasElementEditing.bringingToFront(
                selected,
                in: input,
                within: pageBounds,
                now: later
            ),
            input
        )
        XCTAssertEqual(
            CanvasElementEditing.sendingToBack(
                selected,
                in: input,
                within: pageBounds,
                now: later
            ),
            input
        )
        XCTAssertEqual(
            CanvasElementEditing.deleting(
                lockedID,
                from: input,
                within: pageBounds,
                now: later
            ),
            input
        )
        XCTAssertEqual(
            CanvasElementEditing.duplicating(
                lockedID,
                as: elementID(3),
                in: input,
                within: pageBounds,
                now: later
            ),
            input
        )
        XCTAssertEqual(
            CanvasElementEditing.settingLocked(
                true,
                for: selected,
                in: input,
                within: pageBounds,
                now: later
            ),
            input
        )
    }

    func testLockAndUnlockAreMonotonicEvenWhenClockMovesBackward() throws {
        let createdAt = Date(timeIntervalSince1970: 100)
        let futureModifiedAt = Date(timeIntervalSince1970: 500)
        var item = makeText(id: elementID(1), text: "Item", zIndex: 0, timestamp: createdAt)
        item.modifiedAt = futureModifiedAt

        let locked = CanvasElementEditing.settingLocked(
            true,
            for: Set([item.id]),
            in: [item],
            within: pageBounds,
            now: Date(timeIntervalSince1970: 400)
        )
        XCTAssertTrue(try XCTUnwrap(locked.first).isLocked)
        XCTAssertEqual(try XCTUnwrap(locked.first).modifiedAt, futureModifiedAt)

        let unlocked = CanvasElementEditing.settingLocked(
            false,
            for: Set([item.id]),
            in: locked,
            within: pageBounds,
            now: Date(timeIntervalSince1970: 600)
        )
        XCTAssertFalse(try XCTUnwrap(unlocked.first).isLocked)
        XCTAssertEqual(try XCTUnwrap(unlocked.first).modifiedAt, Date(timeIntervalSince1970: 600))
    }

    func testTranslationContainsRegularElementsAndKeepsGrabAreaForOversizedElements() throws {
        let now = Date(timeIntervalSince1970: 100)
        let regularID = elementID(1)
        let oversizedID = elementID(2)
        let regular = makeText(
            id: regularID,
            frame: CanvasRect(x: 100, y: 100, width: 100, height: 100),
            timestamp: now
        )
        let oversized = makeText(
            id: oversizedID,
            frame: CanvasRect(x: 0, y: 0, width: 800, height: 700),
            zIndex: 1,
            timestamp: now
        )

        let regularMoved = CanvasElementEditing.translating(
            Set([regularID]),
            by: CanvasPoint(x: 10_000, y: 10_000),
            in: [regular],
            within: pageBounds,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(try element(regularID, from: regularMoved).frame,
                       CanvasRect(x: 400, y: 400, width: 100, height: 100))

        let movedToMaximum = CanvasElementEditing.translating(
            Set([oversizedID]),
            by: CanvasPoint(x: 10_000, y: 10_000),
            in: [oversized],
            within: pageBounds,
            now: now.addingTimeInterval(1)
        )
        let maximumFrame = try element(oversizedID, from: movedToMaximum).frame
        XCTAssertEqual(maximumFrame.x, 456)
        XCTAssertEqual(maximumFrame.y, 456)
        XCTAssertEqual(horizontalIntersection(of: maximumFrame, and: pageBounds), 44)
        XCTAssertEqual(verticalIntersection(of: maximumFrame, and: pageBounds), 44)

        let movedToMinimum = CanvasElementEditing.translating(
            Set([oversizedID]),
            by: CanvasPoint(x: -10_000, y: -10_000),
            in: movedToMaximum,
            within: pageBounds,
            now: now.addingTimeInterval(2)
        )
        let minimumFrame = try element(oversizedID, from: movedToMinimum).frame
        XCTAssertEqual(minimumFrame.x, -756)
        XCTAssertEqual(minimumFrame.y, -656)
        XCTAssertEqual(horizontalIntersection(of: minimumFrame, and: pageBounds), 44)
        XCTAssertEqual(verticalIntersection(of: minimumFrame, and: pageBounds), 44)
    }

    func testResizeEnforcesMinimumAndOptionallyPreservesAspectRatio() throws {
        let now = Date(timeIntervalSince1970: 100)
        let itemID = elementID(1)
        let item = makeText(
            id: itemID,
            frame: CanvasRect(x: 20, y: 30, width: 200, height: 100),
            timestamp: now
        )

        let aspectResize = CanvasElementEditing.resizing(
            itemID,
            to: CanvasRect(x: 40, y: 50, width: 400, height: 110),
            preservingAspectRatio: true,
            in: [item],
            within: pageBounds,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(try element(itemID, from: aspectResize).frame,
                       CanvasRect(x: 40, y: 50, width: 400, height: 200))
        XCTAssertEqual(try element(itemID, from: aspectResize).modifiedAt,
                       now.addingTimeInterval(1))

        let minimumResize = CanvasElementEditing.resizing(
            itemID,
            to: CanvasRect(x: 40, y: 50, width: 10, height: -20),
            preservingAspectRatio: false,
            in: [item],
            within: pageBounds,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(try element(itemID, from: minimumResize).frame.width,
                       CanvasElementEditing.minimumInteractiveLength)
        XCTAssertEqual(try element(itemID, from: minimumResize).frame.height,
                       CanvasElementEditing.minimumInteractiveLength)
        XCTAssertEqual(
            try element(itemID, from: minimumResize).frame,
            CanvasRect(x: 40, y: 6, width: 44, height: 44)
        )

        let crossedHandles = CanvasElementEditing.resizing(
            itemID,
            to: CanvasRect(x: 400, y: 300, width: -400, height: -110),
            preservingAspectRatio: true,
            in: [item],
            within: pageBounds,
            now: now.addingTimeInterval(3)
        )
        let crossedFrame = try element(itemID, from: crossedHandles).frame
        XCTAssertEqual(crossedFrame, CanvasRect(x: 0, y: 100, width: 400, height: 200))
        XCTAssertEqual(crossedFrame.x + crossedFrame.width, 400)
        XCTAssertEqual(crossedFrame.y + crossedFrame.height, 300)
    }

    func testConnectorEndpointsTranslateAndResizeInPageCoordinates() throws {
        let now = Date(timeIntervalSince1970: 100)
        let connectorID = elementID(1)
        let connector = CanvasElement(
            id: connectorID,
            frame: CanvasRect(x: 100, y: 100, width: 100, height: 50),
            content: .connector(
                ConnectorElement(
                    start: CanvasPoint(x: 100, y: 125),
                    end: CanvasPoint(x: 200, y: 125),
                    strokeColor: RGBAColor(red: 0, green: 0, blue: 0)
                )
            ),
            createdAt: now,
            modifiedAt: now
        )
        let largeBounds = CanvasRect(x: 0, y: 0, width: 1_000, height: 1_000)

        let translated = CanvasElementEditing.translating(
            Set([connectorID]),
            by: CanvasPoint(x: 20, y: 30),
            in: [connector],
            within: largeBounds,
            now: now.addingTimeInterval(1)
        )
        let translatedElement = try element(connectorID, from: translated)
        XCTAssertEqual(translatedElement.frame, CanvasRect(x: 120, y: 130, width: 100, height: 50))
        let translatedConnector = try connectorContent(in: translatedElement)
        XCTAssertEqual(translatedConnector.start, CanvasPoint(x: 120, y: 155))
        XCTAssertEqual(translatedConnector.end, CanvasPoint(x: 220, y: 155))

        let resized = CanvasElementEditing.resizing(
            connectorID,
            to: CanvasRect(x: 120, y: 130, width: 200, height: 100),
            preservingAspectRatio: false,
            in: translated,
            within: largeBounds,
            now: now.addingTimeInterval(2)
        )
        let resizedConnector = try connectorContent(in: element(connectorID, from: resized))
        XCTAssertEqual(resizedConnector.start, CanvasPoint(x: 120, y: 180))
        XCTAssertEqual(resizedConnector.end, CanvasPoint(x: 320, y: 180))
    }

    func testConnectorUsesContainedDisplacementAndRotationDoesNotRewritePageCoordinates() throws {
        let now = Date(timeIntervalSince1970: 100)
        let connectorID = elementID(1)
        let connector = CanvasElement(
            id: connectorID,
            frame: CanvasRect(x: 350, y: 100, width: 100, height: 50),
            content: .connector(
                ConnectorElement(
                    start: CanvasPoint(x: 350, y: 125),
                    end: CanvasPoint(x: 450, y: 125),
                    strokeColor: RGBAColor(red: 0, green: 0, blue: 0)
                )
            ),
            createdAt: now,
            modifiedAt: now
        )

        let contained = CanvasElementEditing.translating(
            Set([connectorID]),
            by: CanvasPoint(x: 100, y: 0),
            in: [connector],
            within: pageBounds,
            now: now.addingTimeInterval(1)
        )
        let containedElement = try element(connectorID, from: contained)
        XCTAssertEqual(containedElement.frame.x, 400)
        XCTAssertEqual(
            try connectorContent(in: containedElement).start,
            CanvasPoint(x: 400, y: 125)
        )
        XCTAssertEqual(
            try connectorContent(in: containedElement).end,
            CanvasPoint(x: 500, y: 125)
        )

        let pinned = CanvasElementEditing.translating(
            Set([connectorID]),
            by: CanvasPoint(x: 100, y: 0),
            in: contained,
            within: pageBounds,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(pinned, contained)

        let rotated = CanvasElementEditing.rotating(
            Set([connectorID]),
            by: .pi / 2,
            in: contained,
            within: pageBounds,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(
            try connectorContent(in: element(connectorID, from: rotated)),
            try connectorContent(in: containedElement)
        )

        let duplicateID = elementID(2)
        let duplicated = CanvasElementEditing.duplicating(
            connectorID,
            as: duplicateID,
            offset: CanvasPoint(x: 100, y: 0),
            in: contained,
            within: pageBounds,
            now: now.addingTimeInterval(3)
        )
        let duplicate = try element(duplicateID, from: duplicated)
        XCTAssertEqual(duplicate.frame, containedElement.frame)
        XCTAssertEqual(
            try connectorContent(in: duplicate),
            try connectorContent(in: containedElement)
        )
        XCTAssertEqual(duplicated.map(\.id), [connectorID, duplicateID])
    }

    func testRotationAndOpacityNormalizeInvalidAndOutOfRangeInput() throws {
        let now = Date(timeIntervalSince1970: 100)
        let item = makeText(id: elementID(1), text: "Item", zIndex: 0, timestamp: now)
        let selection = Set([item.id])

        let rotated = CanvasElementEditing.rotating(
            selection,
            by: 9 * Double.pi / 2,
            in: [item],
            within: pageBounds,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(try XCTUnwrap(rotated.first).rotationRadians, Double.pi / 2, accuracy: 0.000_000_1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(rotated.first).rotationRadians, -Double.pi)
        XCTAssertLessThan(try XCTUnwrap(rotated.first).rotationRadians, Double.pi)
        XCTAssertEqual(try XCTUnwrap(rotated.first).modifiedAt, now.addingTimeInterval(1))

        let invalidRotation = CanvasElementEditing.rotating(
            selection,
            by: .infinity,
            in: rotated,
            within: pageBounds,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(invalidRotation, rotated)

        let transparent = CanvasElementEditing.settingOpacity(
            -10,
            for: selection,
            in: rotated,
            within: pageBounds,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(try XCTUnwrap(transparent.first).opacity, 0)

        let invalidOpacity = CanvasElementEditing.settingOpacity(
            .nan,
            for: selection,
            in: transparent,
            within: pageBounds,
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(invalidOpacity, transparent)
    }

    func testNormalizationSanitizesExtremeAndNonfiniteGeometryContentAndNegativeFrames() throws {
        let timestamp = Date(timeIntervalSince1970: 100)
        let invalidID = elementID(1)
        var invalid = CanvasElement(
            id: invalidID,
            frame: CanvasRect(
                x: Double.greatestFiniteMagnitude,
                y: .infinity,
                width: -Double.greatestFiniteMagnitude,
                height: -.infinity
            ),
            rotationRadians: .nan,
            zIndex: .max,
            opacity: 1,
            content: .text(
                TextElement(
                    text: "Invalid",
                    fontName: "",
                    fontSize: .nan,
                    color: RGBAColor(red: .infinity, green: -1, blue: 2, alpha: .nan)
                )
            ),
            createdAt: timestamp,
            modifiedAt: timestamp
        )
        invalid.opacity = .nan
        let bottom = makeText(id: elementID(2), text: "Bottom", zIndex: .min, timestamp: timestamp)

        let normalized = CanvasElementEditing.normalized(
            [invalid, bottom],
            within: pageBounds,
            now: timestamp.addingTimeInterval(1)
        )
        XCTAssertEqual(normalized.map(\.id), [bottom.id, invalidID])
        XCTAssertEqual(normalized.map(\.zIndex), [0, 1])

        let result = try element(invalidID, from: normalized)
        XCTAssertTrue(result.frame.x.isFinite)
        XCTAssertTrue(result.frame.y.isFinite)
        XCTAssertGreaterThanOrEqual(result.frame.width, CanvasElementEditing.minimumInteractiveLength)
        XCTAssertGreaterThanOrEqual(result.frame.height, CanvasElementEditing.minimumInteractiveLength)
        XCTAssertTrue(result.rotationRadians.isFinite)
        XCTAssertEqual(result.rotationRadians, 0)
        XCTAssertTrue(result.opacity.isFinite)
        XCTAssertEqual(result.opacity, 1)

        guard case .text(let text) = result.content else {
            return XCTFail("Expected normalized text content")
        }
        XCTAssertEqual(text.fontName, "System")
        XCTAssertEqual(text.fontSize, 17)
        XCTAssertEqual(text.color, RGBAColor(red: 0, green: 0, blue: 1, alpha: 1))
        XCTAssertEqual(result.modifiedAt, timestamp.addingTimeInterval(1))
    }

    func testExtremeZIndicesRenormalizeWithoutOverflowAndPreserveTieOrder() {
        let timestamp = Date(timeIntervalSince1970: 100)
        let firstTie = makeText(id: elementID(1), text: "First tie", zIndex: .max, timestamp: timestamp)
        let bottom = makeText(id: elementID(2), text: "Bottom", zIndex: .min, timestamp: timestamp)
        let secondTie = makeText(id: elementID(3), text: "Second tie", zIndex: .max, timestamp: timestamp)
        let now = timestamp.addingTimeInterval(1)

        let normalized = CanvasElementEditing.normalized(
            [firstTie, bottom, secondTie],
            within: pageBounds,
            now: now
        )
        XCTAssertEqual(normalized.map(\.id), [bottom.id, firstTie.id, secondTie.id])
        XCTAssertEqual(normalized.map(\.zIndex), [0, 1, 2])
        XCTAssertTrue(normalized.allSatisfy { $0.modifiedAt >= timestamp })

        let front = CanvasElementEditing.bringingToFront(
            Set([bottom.id]),
            in: normalized,
            within: pageBounds,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(front.map(\.id), [firstTie.id, secondTie.id, bottom.id])
        XCTAssertEqual(front.map(\.zIndex), [0, 1, 2])
    }

    func testDuplicatePersistedIDsMakeAddressedEditsExactNoOps() {
        let now = Date(timeIntervalSince1970: 100)
        let duplicateID = elementID(1)
        let first = makeText(id: duplicateID, text: "First", zIndex: 0, timestamp: now)
        let second = makeText(id: duplicateID, text: "Second", zIndex: 1, timestamp: now)
        let input = [first, second]
        let later = now.addingTimeInterval(1)

        XCTAssertEqual(
            CanvasElementEditing.deleting(
                duplicateID,
                from: input,
                within: pageBounds,
                now: later
            ),
            input
        )
        XCTAssertEqual(
            CanvasElementEditing.updatingContent(
                of: duplicateID,
                to: .text(TextElement(text: "Ambiguous")),
                in: input,
                within: pageBounds,
                now: later
            ),
            input
        )
        XCTAssertEqual(
            CanvasElementEditing.translating(
                Set([duplicateID]),
                by: CanvasPoint(x: 10, y: 10),
                in: input,
                within: pageBounds,
                now: later
            ),
            input
        )
        XCTAssertEqual(
            CanvasElementEditing.inserting(
                makeText(id: elementID(2), text: "New", zIndex: 2, timestamp: now),
                after: duplicateID,
                in: input,
                within: pageBounds,
                now: later
            ),
            input
        )
    }

    func testExtremePositivePageOriginDoesNotCollapseDistinctElementPositions() throws {
        let now = Date(timeIntervalSince1970: 100)
        let coordinateLimit = 1_000_000_000_000.0
        let bounds = CanvasRect(
            x: coordinateLimit,
            y: coordinateLimit,
            width: 500,
            height: 500
        )
        let leftID = elementID(1)
        let rightID = elementID(2)
        let left = makeText(
            id: leftID,
            frame: CanvasRect(
                x: coordinateLimit - 500,
                y: coordinateLimit - 500,
                width: 100,
                height: 100
            ),
            timestamp: now
        )
        let right = makeText(
            id: rightID,
            frame: CanvasRect(x: coordinateLimit, y: coordinateLimit, width: 100, height: 100),
            zIndex: 1,
            timestamp: now
        )

        let normalized = CanvasElementEditing.normalized(
            [left, right],
            within: bounds,
            now: now.addingTimeInterval(1)
        )
        let normalizedLeft = try element(leftID, from: normalized)
        let normalizedRight = try element(rightID, from: normalized)

        XCTAssertEqual(normalizedLeft.frame.x, coordinateLimit - 500)
        XCTAssertEqual(normalizedLeft.frame.y, coordinateLimit - 500)
        XCTAssertEqual(normalizedRight.frame.x, coordinateLimit - 100)
        XCTAssertEqual(normalizedRight.frame.y, coordinateLimit - 100)
        XCTAssertNotEqual(normalizedLeft.frame, normalizedRight.frame)
        XCTAssertLessThanOrEqual(normalizedRight.frame.x + normalizedRight.frame.width, coordinateLimit)
        XCTAssertLessThanOrEqual(normalizedRight.frame.y + normalizedRight.frame.height, coordinateLimit)
    }

    func testEveryMutationKeepsModifiedAtMonotonic() throws {
        let originalModifiedAt = Date(timeIntervalSince1970: 500)
        var first = makeText(
            id: elementID(1),
            text: "First",
            zIndex: 0,
            timestamp: Date(timeIntervalSince1970: 100)
        )
        first.modifiedAt = originalModifiedAt
        let second = makeText(
            id: elementID(2),
            text: "Second",
            zIndex: 1,
            timestamp: Date(timeIntervalSince1970: 100)
        )

        let edited = CanvasElementEditing.updatingContent(
            of: first.id,
            to: .text(TextElement(text: "Edited")),
            in: [first, second],
            within: pageBounds,
            now: Date(timeIntervalSince1970: 400)
        )
        XCTAssertEqual(try element(first.id, from: edited).modifiedAt, originalModifiedAt)

        let moved = CanvasElementEditing.translating(
            Set([first.id]),
            by: CanvasPoint(x: 10, y: 10),
            in: edited,
            within: pageBounds,
            now: Date(timeIntervalSince1970: 600)
        )
        XCTAssertEqual(try element(first.id, from: moved).modifiedAt, Date(timeIntervalSince1970: 600))

        let beforeReorder = Dictionary(uniqueKeysWithValues: moved.map { ($0.id, $0.modifiedAt) })
        let reordered = CanvasElementEditing.sendingToBack(
            Set([second.id]),
            in: moved,
            within: pageBounds,
            now: Date(timeIntervalSince1970: 550)
        )
        for element in reordered {
            XCTAssertGreaterThanOrEqual(element.modifiedAt, try XCTUnwrap(beforeReorder[element.id]))
        }

        let editedWithInvalidClock = CanvasElementEditing.updatingContent(
            of: first.id,
            to: .text(TextElement(text: "Edited with invalid clock")),
            in: moved,
            within: pageBounds,
            now: Date(timeIntervalSinceReferenceDate: .nan)
        )
        XCTAssertEqual(
            try element(first.id, from: editedWithInvalidClock).modifiedAt,
            Date(timeIntervalSince1970: 600)
        )
    }

    func testNormalizationRepairsInvalidDatesWithoutProducingNonfiniteTimestamps() throws {
        let now = Date(timeIntervalSince1970: 300)
        var item = makeText(
            id: elementID(1),
            text: "Invalid dates",
            zIndex: 0,
            timestamp: Date(timeIntervalSince1970: 100)
        )
        item.createdAt = Date(timeIntervalSinceReferenceDate: .nan)
        item.modifiedAt = Date(timeIntervalSinceReferenceDate: .infinity)

        let normalized = CanvasElementEditing.normalized(
            [item],
            within: pageBounds,
            now: now
        )
        let result = try XCTUnwrap(normalized.first)
        XCTAssertTrue(result.createdAt.timeIntervalSinceReferenceDate.isFinite)
        XCTAssertTrue(result.modifiedAt.timeIntervalSinceReferenceDate.isFinite)
        XCTAssertEqual(result.createdAt, now)
        XCTAssertEqual(result.modifiedAt, now)
    }

    func testFactoriesCreateDistinctOriginalDefaultsWithCallerSuppliedIDs() throws {
        let now = Date(timeIntervalSince1970: 100)
        let origin = CanvasPoint(x: 20, y: 30)
        let text = CanvasElementEditing.makeText(
            id: elementID(1),
            at: origin,
            within: pageBounds,
            now: now
        )
        let shape = CanvasElementEditing.makeShape(
            id: elementID(2),
            at: origin,
            within: pageBounds,
            now: now
        )
        let sticky = CanvasElementEditing.makeStickyNote(
            id: elementID(3),
            at: origin,
            within: pageBounds,
            now: now
        )
        let tape = CanvasElementEditing.makeTape(
            id: elementID(4),
            at: origin,
            within: pageBounds,
            now: now
        )
        let destination = try XCTUnwrap(URL(string: "https://example.test/path"))
        let link = CanvasElementEditing.makeLink(
            id: elementID(5),
            title: "  ",
            destination: destination,
            at: origin,
            within: pageBounds,
            now: now
        )

        XCTAssertEqual([text.id, shape.id, sticky.id, tape.id, link.id],
                       [elementID(1), elementID(2), elementID(3), elementID(4), elementID(5)])
        XCTAssertEqual(text.frame.width, 240)
        XCTAssertEqual(shape.frame, CanvasRect(x: 20, y: 30, width: 180, height: 120))
        XCTAssertEqual(sticky.frame.width, 180)
        XCTAssertEqual(tape.frame.height, 56)
        guard case .text = text.content,
              case .shape = shape.content,
              case .stickyNote = sticky.content,
              case .tape = tape.content,
              case .link(let linkContent) = link.content else {
            return XCTFail("Factories returned an unexpected content type")
        }
        XCTAssertEqual(linkContent.title, "Link")
        XCTAssertEqual(linkContent.destination, destination)
        XCTAssertTrue([text, shape, sticky, tape, link].allSatisfy {
            $0.createdAt == now && $0.modifiedAt == now
        })
    }

    func testMixedSelectionMovesUnlockedElementsAndLeavesLockedElementUntouched() throws {
        let now = Date(timeIntervalSince1970: 100)
        let locked = makeText(
            id: elementID(1),
            text: "Locked",
            zIndex: 0,
            isLocked: true,
            timestamp: now
        )
        let movable = makeText(id: elementID(2), text: "Movable", zIndex: 1, timestamp: now)

        let result = CanvasElementEditing.translating(
            Set([locked.id, movable.id]),
            by: CanvasPoint(x: 25, y: 30),
            in: [locked, movable],
            within: pageBounds,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(try element(locked.id, from: result), locked)
        XCTAssertEqual(try element(movable.id, from: result).frame.x, movable.frame.x + 25)
        XCTAssertEqual(try element(movable.id, from: result).frame.y, movable.frame.y + 30)
    }

    // MARK: - Helpers

    private func elementID(_ value: UInt8) -> ElementID {
        let suffix = String(format: "%012x", value)
        return ElementID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!)
    }

    private func makeText(
        id: ElementID,
        text: String,
        zIndex: Int,
        isLocked: Bool = false,
        timestamp: Date
    ) -> CanvasElement {
        makeText(
            id: id,
            text: text,
            frame: CanvasRect(x: 50, y: 60, width: 120, height: 80),
            zIndex: zIndex,
            isLocked: isLocked,
            timestamp: timestamp
        )
    }

    private func makeText(
        id: ElementID,
        text: String = "Item",
        frame: CanvasRect,
        zIndex: Int = 0,
        isLocked: Bool = false,
        timestamp: Date
    ) -> CanvasElement {
        CanvasElement(
            id: id,
            frame: frame,
            zIndex: zIndex,
            isLocked: isLocked,
            content: .text(TextElement(text: text)),
            createdAt: timestamp,
            modifiedAt: timestamp
        )
    }

    private func element(_ id: ElementID, from elements: [CanvasElement]) throws -> CanvasElement {
        try XCTUnwrap(elements.first(where: { $0.id == id }))
    }

    private func text(in element: CanvasElement) -> String? {
        guard case .text(let text) = element.content else { return nil }
        return text.text
    }

    private func connectorContent(in element: CanvasElement) throws -> ConnectorElement {
        guard case .connector(let connector) = element.content else {
            throw TestError.unexpectedContent
        }
        return connector
    }

    private func horizontalIntersection(of lhs: CanvasRect, and rhs: CanvasRect) -> Double {
        max(0, min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x))
    }

    private func verticalIntersection(of lhs: CanvasRect, and rhs: CanvasRect) -> Double {
        max(0, min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y))
    }
}

private enum TestError: Error {
    case unexpectedContent
}
