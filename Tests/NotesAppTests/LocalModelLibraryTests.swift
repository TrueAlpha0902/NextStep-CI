import CryptoKit
import Darwin
import Foundation
import NotesServices
@testable import NotesApp
import XCTest

final class LocalModelLibraryTests: XCTestCase {
    @MainActor
    func testViewModelRefreshImportAndRemoveUseVerifiedStoreState() async throws {
        let first = makeInstalledModel(id: "first", installedAt: Date(timeIntervalSince1970: 10))
        let second = makeInstalledModel(id: "second", installedAt: Date(timeIntervalSince1970: 20))
        let store = FakeLocalModelLibrary(models: [first])
        let viewModel = LocalModelLibrary(store: store)

        await viewModel.refresh()
        XCTAssertEqual(viewModel.models.map(\.id), ["first"])
        XCTAssertNotNil(viewModel.lastVerifiedAt)
        XCTAssertNil(viewModel.failureMessage)

        await store.setImportResult(second)
        await viewModel.importPackage(from: URL(fileURLWithPath: "/unused"))
        XCTAssertEqual(Set(viewModel.models.map(\.id)), Set(["first", "second"]))

        await viewModel.removeModel(id: "first")
        XCTAssertEqual(viewModel.models.map(\.id), ["second"])
        let removedIDs = await store.removedModelIDs()
        XCTAssertEqual(removedIDs, ["first"])
        XCTAssertEqual(viewModel.operation, .idle)
    }

    @MainActor
    func testViewModelDoesNotPresentCancellationAsAnError() async {
        let store = FakeLocalModelLibrary(models: [], installedModelsError: CancellationError())
        let viewModel = LocalModelLibrary(store: store)

        await viewModel.refresh()

        XCTAssertTrue(viewModel.models.isEmpty)
        XCTAssertNil(viewModel.failureMessage)
        XCTAssertEqual(viewModel.operation, .idle)
    }

    func testLocalPackageImportVerifiesPersistsAndRechecksSHA256() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = sandbox.appendingPathComponent("source", isDirectory: true)
        let root = sandbox.appendingPathComponent("installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let artifactData = Data("fully local model artifact".utf8)
        let artifactName = "weights/model.bin"
        let artifactURL = source.appendingPathComponent(artifactName)
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try artifactData.write(to: artifactURL)
        let descriptor = makeDescriptor(
            id: "local-model",
            artifactPath: artifactName,
            artifactData: artifactData
        )
        try writePackageManifest(descriptor: descriptor, to: source)

        let library = OnDeviceModelLibrary(
            rootDirectory: root,
            limits: ModelDownloadLimits(
                maximumArtifactCount: 4,
                maximumArtifactBytes: 1_024 * 1_024,
                maximumModelBytes: 2 * 1_024 * 1_024,
                freeSpaceReserveBytes: 0
            )
        )

        let installed = try await library.importPackage(from: source)
        let verifiedModelIDs = try await library.installedModels().map(\.id)
        XCTAssertEqual(installed.id, descriptor.id)
        XCTAssertEqual(verifiedModelIDs, [descriptor.id])
        XCTAssertEqual(
            try Data(contentsOf: installed.directoryURL.appendingPathComponent(artifactName)),
            artifactData
        )

        try Data("tampered".utf8).write(
            to: installed.directoryURL.appendingPathComponent(artifactName),
            options: .atomic
        )
        do {
            _ = try await library.installedModels()
            XCTFail("Expected installed artifacts to be reverified")
        } catch let error as LocalModelPackageError {
            XCTAssertEqual(error, .checksumMismatch(artifactName))
        }

        try await library.removeModel(id: descriptor.id)
        let remainingModels = try await library.installedModels()
        XCTAssertTrue(remainingModels.isEmpty)
    }

    func testLocalPackageImportRejectsPathTraversalBeforeCopying() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = sandbox.appendingPathComponent("source", isDirectory: true)
        let root = sandbox.appendingPathComponent("installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let artifactData = Data("unsafe".utf8)
        let descriptor = makeDescriptor(
            id: "unsafe-model",
            artifactPath: "../escape.bin",
            artifactData: artifactData
        )
        try writePackageManifest(descriptor: descriptor, to: source)
        let library = OnDeviceModelLibrary(rootDirectory: root)

        do {
            _ = try await library.importPackage(from: source)
            XCTFail("Expected path traversal to be rejected")
        } catch let error as LocalModelPackageError {
            XCTAssertEqual(error, .unsafePath("../escape.bin"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unsafe-model").path))
    }

    func testLocalPackageImportRejectsReservedManifestArtifactPaths() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        for (index, artifactPath) in ["model.json", "MODEL.JSON"].enumerated() {
            let source = sandbox.appendingPathComponent("source-\(index)", isDirectory: true)
            let root = sandbox.appendingPathComponent("installed-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let descriptor = makeDescriptor(
                id: "reserved-manifest-\(index)",
                artifactPath: artifactPath,
                artifactData: Data("reserved".utf8)
            )
            try writePackageManifest(descriptor: descriptor, to: source)
            let library = OnDeviceModelLibrary(rootDirectory: root, limits: testLimits)

            do {
                _ = try await library.importPackage(from: source)
                XCTFail("Expected the manifest name to remain reserved for artifacts")
            } catch let error as LocalModelPackageError {
                XCTAssertEqual(error, .unsafePath(artifactPath))
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(descriptor.id).path
                )
            )
        }
    }

    func testLocalPackageImportRejectsIdentifierWithTrailingControlCharacter() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = sandbox.appendingPathComponent("source", isDirectory: true)
        let root = sandbox.appendingPathComponent("installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let descriptor = makeDescriptor(
            id: "unsafe-model\n",
            artifactPath: "model.bin",
            artifactData: Data("unsafe".utf8)
        )
        try writePackageManifest(descriptor: descriptor, to: source)
        let library = OnDeviceModelLibrary(rootDirectory: root, limits: testLimits)

        do {
            _ = try await library.importPackage(from: source)
            XCTFail("Expected a control character in the identifier to be rejected")
        } catch let error as LocalModelPackageError {
            XCTAssertEqual(error, .unsafePath("unsafe-model\n"))
        }
    }

    func testLocalPackageImportRejectsCaseAndUnicodeEquivalentArtifactPaths() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = sandbox.appendingPathComponent("source", isDirectory: true)
        let root = sandbox.appendingPathComponent("installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let firstData = Data("first".utf8)
        let secondData = Data("second".utf8)
        var descriptor = makeDescriptor(
            id: "colliding-model",
            artifactPath: "Weights/caf\u{00E9}.bin",
            artifactData: firstData
        )
        descriptor.artifacts.append(
            makeArtifact(relativePath: "weights/cafe\u{0301}.BIN", data: secondData)
        )
        try writePackageManifest(descriptor: descriptor, to: source)
        let library = OnDeviceModelLibrary(rootDirectory: root, limits: testLimits)

        do {
            _ = try await library.importPackage(from: source)
            XCTFail("Expected canonical path collisions to be rejected")
        } catch let error as LocalModelPackageError {
            XCTAssertEqual(
                error,
                .invalidPackage("the manifest contains colliding artifact paths")
            )
        }
    }

    func testLocalPackageImportRejectsCaseEquivalentInstalledIdentifier() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = sandbox.appendingPathComponent("source", isDirectory: true)
        let root = sandbox.appendingPathComponent("installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("LOCAL-MODEL"),
            withIntermediateDirectories: true
        )
        let descriptor = makeDescriptor(
            id: "local-model",
            artifactPath: "model.bin",
            artifactData: Data("model".utf8)
        )
        try writePackageManifest(descriptor: descriptor, to: source)
        let library = OnDeviceModelLibrary(rootDirectory: root, limits: testLimits)

        do {
            _ = try await library.importPackage(from: source)
            XCTFail("Expected case-equivalent identifiers to collide")
        } catch let error as LocalModelPackageError {
            XCTAssertEqual(error, .modelAlreadyInstalled("local-model"))
        }
    }

    func testLocalPackageImportRejectsArtifactPathThatIsAnotherArtifactsDirectory() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = sandbox.appendingPathComponent("source", isDirectory: true)
        let root = sandbox.appendingPathComponent("installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let artifactData = Data("weights".utf8)
        var descriptor = makeDescriptor(
            id: "prefix-collision-model",
            artifactPath: "weights",
            artifactData: artifactData
        )
        descriptor.artifacts.append(
            makeArtifact(relativePath: "WEIGHTS/model.bin", data: artifactData)
        )
        try writePackageManifest(descriptor: descriptor, to: source)
        let library = OnDeviceModelLibrary(rootDirectory: root, limits: testLimits)

        do {
            _ = try await library.importPackage(from: source)
            XCTFail("Expected file and directory path collisions to be rejected")
        } catch let error as LocalModelPackageError {
            XCTAssertEqual(
                error,
                .invalidPackage("the manifest contains colliding artifact paths")
            )
        }
    }

    func testLocalPackageImportRejectsHardLinkedArtifact() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = sandbox.appendingPathComponent("source", isDirectory: true)
        let root = sandbox.appendingPathComponent("installed", isDirectory: true)
        let outside = sandbox.appendingPathComponent("outside.bin")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let artifactData = Data("linked secret".utf8)
        try artifactData.write(to: outside)
        let artifactPath = "weights/model.bin"
        let artifactURL = source.appendingPathComponent(artifactPath)
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.linkItem(at: outside, to: artifactURL)
        let descriptor = makeDescriptor(
            id: "linked-model",
            artifactPath: artifactPath,
            artifactData: artifactData
        )
        try writePackageManifest(descriptor: descriptor, to: source)
        let library = OnDeviceModelLibrary(rootDirectory: root, limits: testLimits)

        do {
            _ = try await library.importPackage(from: source)
            XCTFail("Expected hard-linked artifacts to be rejected")
        } catch let error as LocalModelPackageError {
            guard case .invalidPackage = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("linked-model").path))
    }

    func testLocalPackageImportRejectsSymlinkedArtifactDirectory() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = sandbox.appendingPathComponent("source", isDirectory: true)
        let outside = sandbox.appendingPathComponent("outside", isDirectory: true)
        let root = sandbox.appendingPathComponent("installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let artifactData = Data("outside model".utf8)
        try artifactData.write(to: outside.appendingPathComponent("model.bin"))
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("weights"),
            withDestinationURL: outside
        )
        let descriptor = makeDescriptor(
            id: "symlinked-model",
            artifactPath: "weights/model.bin",
            artifactData: artifactData
        )
        try writePackageManifest(descriptor: descriptor, to: source)
        let library = OnDeviceModelLibrary(rootDirectory: root, limits: testLimits)

        do {
            _ = try await library.importPackage(from: source)
            XCTFail("Expected symlinked artifact directories to be rejected")
        } catch let error as LocalModelPackageError {
            guard case .invalidPackage = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLocalPackageImportRejectsFIFOWithoutBlocking() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = sandbox.appendingPathComponent("source", isDirectory: true)
        let root = sandbox.appendingPathComponent("installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let artifactPath = "model.pipe"
        let fifoURL = source.appendingPathComponent(artifactPath)
        let fifoResult = fifoURL.path.withCString {
            Darwin.mkfifo($0, mode_t(S_IRUSR | S_IWUSR))
        }
        XCTAssertEqual(fifoResult, 0)
        let descriptor = makeDescriptor(
            id: "fifo-model",
            artifactPath: artifactPath,
            artifactData: Data("not read".utf8)
        )
        try writePackageManifest(descriptor: descriptor, to: source)
        let library = OnDeviceModelLibrary(rootDirectory: root, limits: testLimits)

        do {
            _ = try await library.importPackage(from: source)
            XCTFail("Expected a FIFO artifact to be rejected")
        } catch let error as LocalModelPackageError {
            guard case .invalidPackage = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testChecksumFailureRollsBackAllStagedFiles() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = sandbox.appendingPathComponent("source", isDirectory: true)
        let root = sandbox.appendingPathComponent("installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let actualData = Data("actual data".utf8)
        let artifactPath = "weights/model.bin"
        let artifactURL = source.appendingPathComponent(artifactPath)
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try actualData.write(to: artifactURL)
        let descriptor = makeDescriptor(
            id: "checksum-model",
            artifactPath: artifactPath,
            artifactData: Data("wrong digest".utf8)
        )
        try writePackageManifest(descriptor: descriptor, to: source)
        let library = OnDeviceModelLibrary(rootDirectory: root, limits: testLimits)

        do {
            _ = try await library.importPackage(from: source)
            XCTFail("Expected checksum verification to fail")
        } catch let error as LocalModelPackageError {
            XCTAssertEqual(error, .checksumMismatch(artifactPath))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("checksum-model").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    private func makeInstalledModel(id: String, installedAt: Date) -> InstalledModel {
        InstalledModel(
            descriptor: Self.makeDescriptor(
                id: id,
                artifactPath: "model.bin",
                artifactData: Data(id.utf8)
            ),
            directoryURL: URL(fileURLWithPath: "/models/\(id)"),
            installedAt: installedAt
        )
    }

    private static func makeDescriptor(
        id: String,
        artifactPath: String,
        artifactData: Data
    ) -> ModelDescriptor {
        ModelDescriptor(
            id: id,
            displayName: "Local \(id)",
            version: "1.0",
            licenseName: "Apache-2.0",
            licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
            artifacts: [
                ModelArtifact(
                    relativePath: artifactPath,
                    remoteURL: URL(string: "https://example.com/models/\(id).bin")!,
                    sha256: SHA256.hash(data: artifactData)
                        .map { String(format: "%02x", $0) }
                        .joined(),
                    approximateBytes: Int64(artifactData.count)
                )
            ]
        )
    }

    private func makeArtifact(relativePath: String, data: Data) -> ModelArtifact {
        ModelArtifact(
            relativePath: relativePath,
            remoteURL: URL(string: "https://example.com/models/artifact.bin")!,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            approximateBytes: Int64(data.count)
        )
    }

    private var testLimits: ModelDownloadLimits {
        ModelDownloadLimits(
            maximumArtifactCount: 8,
            maximumArtifactBytes: 1_024 * 1_024,
            maximumModelBytes: 2 * 1_024 * 1_024,
            freeSpaceReserveBytes: 0
        )
    }

    private func makeDescriptor(
        id: String,
        artifactPath: String,
        artifactData: Data
    ) -> ModelDescriptor {
        Self.makeDescriptor(id: id, artifactPath: artifactPath, artifactData: artifactData)
    }

    private func writePackageManifest(descriptor: ModelDescriptor, to directory: URL) throws {
        struct Manifest: Encodable {
            var schemaVersion = 1
            var descriptor: ModelDescriptor
            var installedAt: Date?
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Manifest(descriptor: descriptor, installedAt: nil))
        try data.write(to: directory.appendingPathComponent("model.json"), options: .atomic)
    }
}

private actor FakeLocalModelLibrary: LocalModelLibraryManaging {
    private var models: [InstalledModel]
    private var importedModel: InstalledModel?
    private var removedIDs: [String] = []
    private let installedModelsError: (any Error & Sendable)?

    init(
        models: [InstalledModel],
        installedModelsError: (any Error & Sendable)? = nil
    ) {
        self.models = models
        self.installedModelsError = installedModelsError
    }

    func setImportResult(_ model: InstalledModel) {
        importedModel = model
    }

    func removedModelIDs() -> [String] {
        removedIDs
    }

    func importPackage(from sourceDirectory: URL) async throws -> InstalledModel {
        guard let importedModel else {
            throw LocalModelPackageError.invalidPackage("no test import result")
        }
        models.append(importedModel)
        return importedModel
    }

    func installedModels() async throws -> [InstalledModel] {
        if let installedModelsError { throw installedModelsError }
        return models
    }

    func removeModel(id: String) async throws {
        removedIDs.append(id)
        models.removeAll { $0.id == id }
    }
}
