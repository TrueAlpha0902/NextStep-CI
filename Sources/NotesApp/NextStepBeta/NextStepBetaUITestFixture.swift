import CryptoKit
import Foundation
import NextStepDomain

/// Builds the native UI-test workspace without opening or mutating the user's
/// production NextStep or Notes stores. The launch route is reachable only
/// through the explicit `-nextstep-beta-ui-test` process argument.
enum NextStepBetaUITestFixture {
    private static let fixedNow = Date(timeIntervalSince1970: 1_784_077_200)
    private static let deviceID = DeviceID(
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    )
    private static let sourceID = SourceDocumentID(
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xA1))
    )

    @MainActor
    static func makeModel() -> NextStepBetaModel {
        let fileManager = FileManager()
        let root = isolatedRoot(fileManager: fileManager)
        do {
            let archive = try makeArchive(root: root, fileManager: fileManager)
            return NextStepBetaModel(
                store: NextStepBetaStore(rootURL: root),
                importer: NextStepBetaSourceImporter(applicationSupportRoot: root),
                now: { fixedNow },
                bootstrapArchive: archive
            )
        } catch {
            return NextStepBetaModel(
                store: NextStepBetaStore(rootURL: root),
                importer: NextStepBetaSourceImporter(applicationSupportRoot: root),
                now: { fixedNow },
                initialLoadFailure: "無法建立隔離的 UI 測試資料：\(error.localizedDescription)"
            )
        }
    }

    private static func isolatedRoot(fileManager: FileManager) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("NextStepBetaUITests", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(
                "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private static func makeArchive(
        root: URL,
        fileManager: FileManager
    ) throws -> NextStepBetaArchive {
        var archive = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: fixedNow,
            deviceID: deviceID,
            timeZoneIdentifier: "Asia/Taipei"
        )
        let deadline = try LocalDay(
            date: fixedNow.addingTimeInterval(90 * 86_400),
            timeZoneIdentifier: "Asia/Taipei"
        )
        archive = try NextStepBetaGoalBuilder().addGoal(
            title: "完成 NextStep Beta 驗收",
            deadline: deadline,
            dailyMinutes: 35,
            to: archive,
            now: fixedNow
        )

        let sourceData = makePDF()
        let sourceDirectory = root
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(sourceID.description.uppercased(), isDirectory: true)
        let sourceURL = sourceDirectory.appendingPathComponent("original.pdf")
        try fileManager.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try sourceData.write(to: sourceURL, options: [.atomic])

        let relativePath = "Sources/\(sourceID.description.uppercased())/original.pdf"
        let sha256 = SHA256.hash(data: sourceData)
            .map { String(format: "%02x", $0) }
            .joined()
        let document = try NextStepBetaSourceRecordBuilder().makeDocument(
            id: sourceID,
            displayTitle: "NextStep Beta Evidence.pdf",
            fileExtension: "pdf",
            relativePath: relativePath,
            contentSHA256: sha256,
            now: fixedNow,
            deviceID: deviceID,
            parserVersion: "ui-test-exact-pdf-v1"
        )
        let exactExtract = [
            "Debt changes the capital structure.",
            "Evidence must remain traceable to its source.",
            "A daily action requires three verified points.",
            "Assignment deadline: 2026-09-30."
        ].joined(separator: "\n")
        archive = try NextStepBetaPackageBuilder().addImportedSource(
            NextStepBetaImportedSource(
                document: document,
                exactExtract: exactExtract,
                pageIndex: 0,
                usedVisionOCR: false,
                extractionNotice: nil
            ),
            to: archive,
            now: fixedNow
        )
        return try NextStepBetaPlanningBridge().replan(
            archive: archive,
            trigger: .sourceImported,
            now: fixedNow
        )
    }

    /// A tiny valid one-page PDF. Its visible text is the exact extract stored
    /// in the fixture's source anchor and Guided Learning Package.
    private static func makePDF() -> Data {
        let stream = """
        BT
        /F1 18 Tf
        54 730 Td
        (NextStep Beta Evidence) Tj
        0 -42 Td
        /F1 12 Tf
        (Debt changes the capital structure.) Tj
        0 -24 Td
        (Evidence must remain traceable to its source.) Tj
        0 -24 Td
        (A daily action requires three verified points.) Tj
        0 -24 Td
        (Assignment deadline: 2026-09-30.) Tj
        ET
        """
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        var pdf = "%PDF-1.4\n"
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n"
        pdf += "0000000000 65535 f \n"
        for offset in offsets.dropFirst() {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        pdf += "startxref\n\(xrefOffset)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}
