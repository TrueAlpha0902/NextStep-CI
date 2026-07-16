import CryptoKit
import Foundation
import NextStepDomain
@testable import NotesApp
import XCTest

final class NextStepBetaImportBuilderTests: XCTestCase {
    func testExtractivePackageAndReplanDoNotOverwriteHardDeadline() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let deviceID = DeviceID()
        var archive = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now,
            deviceID: deviceID,
            timeZoneIdentifier: "Asia/Taipei"
        )
        let hardDeadline = try LocalDay(year: 2027, month: 6, day: 30)
        archive = try NextStepBetaGoalBuilder().addGoal(
            title: "完成研究計畫",
            deadline: hardDeadline,
            dailyMinutes: 35,
            to: archive,
            now: now
        )
        let documentID = SourceDocumentID()
        let document = try NextStepBetaSourceRecordBuilder().makeDocument(
            id: documentID,
            displayTitle: "research.pdf",
            fileExtension: "pdf",
            relativePath: "Sources/\(documentID.description)/original.pdf",
            contentSHA256: String(repeating: "a", count: 64),
            now: now,
            deviceID: deviceID,
            parserVersion: "pdfkit-first-page-v1"
        )
        let imported = NextStepBetaImportedSource(
            document: document,
            exactExtract: "This exact sentence came from the imported first page.",
            pageIndex: 0,
            usedVisionOCR: false,
            extractionNotice: nil
        )

        archive = try NextStepBetaPackageBuilder().addImportedSource(
            imported,
            to: archive,
            now: now
        )
        archive = try NextStepBetaPlanningBridge().replan(
            archive: archive,
            trigger: .sourceImported,
            now: now
        )

        let action = try XCTUnwrap(archive.workspace.dailyActions.first)
        let package = try XCTUnwrap(archive.workspace.guidedPackages.first)
        let anchor = try XCTUnwrap(archive.workspace.sourceAnchors.first)
        let evidence = try XCTUnwrap(archive.workspace.evidenceLinks.first)
        let expectedToday = try LocalDay(date: now, timeZoneIdentifier: "Asia/Taipei")

        XCTAssertEqual(action.deadline?.value, hardDeadline)
        XCTAssertEqual(action.deadline?.authority, .userConfirmed)
        XCTAssertEqual(action.deadline?.mutability, .immutable)
        XCTAssertEqual(archive.workspace.ultimateGoals.first?.targetDay?.value, hardDeadline)
        XCTAssertTrue(package.summary.contains("AI 未使用"))
        XCTAssertEqual(package.generatedBy.kind, .deterministicEngine)
        XCTAssertEqual(package.corePoints.first?.text, imported.exactExtract)
        let quiz = try XCTUnwrap(package.quiz)
        XCTAssertEqual(quiz.items.count, 1)
        XCTAssertEqual(quiz.passingFraction, 1)
        XCTAssertEqual(
            Set(action.completionCriteria.map(\.kind)),
            Set([.userAttestation, .quizScore])
        )
        XCTAssertEqual(
            archive.workspace.evidenceLinks.filter { $0.subjectType == "QuizItem" }.count,
            quiz.items.count
        )
        XCTAssertEqual(
            Set(quiz.items.flatMap(\.evidenceLinkIDs)),
            Set(archive.workspace.evidenceLinks
                .filter { $0.subjectType == "QuizItem" }
                .map(\.metadata.id))
        )
        XCTAssertEqual(evidence.anchorID, anchor.metadata.id)
        XCTAssertEqual(archive.currentDecision?.assignments.first?.day, expectedToday)

        if case let .pdf(pageIndex, _, textQuote) = anchor.locator {
            XCTAssertEqual(pageIndex, 0)
            XCTAssertEqual(textQuote, imported.exactExtract)
        } else {
            XCTFail("The v1 first-page adapter should retain a page locator")
        }
    }

    func testImporterCopiesToGeneratedApplicationSupportPathBeforeOCR() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextstep-beta-import-\(UUID().uuidString)", isDirectory: true)
        let inputFolder = base.appendingPathComponent("input", isDirectory: true)
        let appSupport = base.appendingPathComponent("app-support", isDirectory: true)
        try FileManager.default.createDirectory(
            at: inputFolder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: base) }
        let inputURL = inputFolder.appendingPathComponent("user supplied.png")
        let bytes = Data("not-a-real-image".utf8)
        try bytes.write(to: inputURL)

        let importer = NextStepBetaSourceImporter(applicationSupportRoot: appSupport)
        let imported = try await importer.importSource(
            from: inputURL,
            now: Date(timeIntervalSince1970: 1_750_000_000),
            deviceID: DeviceID()
        )

        let relativePath = try XCTUnwrap(imported.document.localRelativePath)
        XCTAssertTrue(relativePath.hasPrefix("Sources/"))
        XCTAssertTrue(relativePath.hasSuffix("/original.png"))
        XCTAssertFalse(relativePath.contains("user supplied"))
        XCTAssertEqual(imported.document.type, .image)
        XCTAssertEqual(imported.document.contentSHA256,
                       SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertNil(imported.exactExtract)
        XCTAssertNotNil(imported.extractionNotice)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: appSupport.appendingPathComponent(relativePath).path
            )
        )
    }

    func testImageExtractUsesImageLocatorInsteadOfPDFAdapter() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let deviceID = DeviceID()
        var archive = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now,
            deviceID: deviceID,
            timeZoneIdentifier: "Asia/Taipei"
        )
        archive = try NextStepBetaGoalBuilder().addGoal(
            title: "完成影像來源複習",
            deadline: try LocalDay(year: 2027, month: 6, day: 30),
            dailyMinutes: 25,
            to: archive,
            now: now
        )
        let documentID = SourceDocumentID()
        let document = try NextStepBetaSourceRecordBuilder().makeDocument(
            id: documentID,
            displayTitle: "scan.png",
            fileExtension: "png",
            relativePath: "Sources/\(documentID.description)/original.png",
            contentSHA256: String(repeating: "b", count: 64),
            now: now,
            deviceID: deviceID,
            parserVersion: "vision-ocr-first-page-v1"
        )

        archive = try NextStepBetaPackageBuilder().addImportedSource(
            NextStepBetaImportedSource(
                document: document,
                exactExtract: "OCR text grounded to the full imported image.",
                pageIndex: 0,
                usedVisionOCR: true,
                extractionNotice: nil
            ),
            to: archive,
            now: now
        )

        let anchor = try XCTUnwrap(archive.workspace.sourceAnchors.first)
        XCTAssertNil(archive.workspace.guidedPackages.first?.quiz)
        XCTAssertFalse(
            archive.workspace.dailyActions.first?.completionCriteria.contains {
                $0.kind == .quizScore
            } ?? true
        )
        guard case let .image(pageIndex, region, textQuote) = anchor.locator else {
            XCTFail("Image OCR must keep an image locator.")
            return
        }
        XCTAssertEqual(pageIndex, 0)
        XCTAssertEqual(region, try NormalizedRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(textQuote, "OCR text grounded to the full imported image.")
    }
}
