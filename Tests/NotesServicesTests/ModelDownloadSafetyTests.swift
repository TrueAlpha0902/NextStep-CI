import CryptoKit
import Foundation
import Testing
@testable import NotesServices

@Suite("Model download safety", .serialized)
struct ModelDownloadSafetyTests {
    @Test("Artifact paths cannot traverse, alias, or replace the manifest")
    func unsafeArtifactPathsAreRejected() async throws {
        let root = try temporaryDirectory(named: "ModelPaths")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelDownloadManager(rootDirectory: root)

        for path in ["../escape.bin", "nested/../../escape.bin", "folder\\escape.bin", "model.json"] {
            do {
                _ = try await manager.install(descriptor(path: path))
                Issue.record("Unsafe path was accepted: \(path)")
            } catch let error as ModelDownloadError {
                guard case .unsafePath = error else {
                    Issue.record("Unexpected error for \(path): \(error)")
                    continue
                }
            }
        }
    }

    @Test("Descriptors require secure URLs, checksums, unique paths, and sane sizes")
    func maliciousDescriptorsAreRejected() async throws {
        let root = try temporaryDirectory(named: "ModelDescriptors")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelDownloadManager(rootDirectory: root)

        var insecure = descriptor(path: "weights.bin")
        insecure.artifacts[0].remoteURL = URL(string: "http://example.invalid/weights.bin")!
        await #expect(throws: ModelDownloadError.unsupportedURL("http://example.invalid/weights.bin")) {
            try await manager.install(insecure)
        }

        for privateURL in [
            "https://localhost/weights.bin",
            "https://127.0.0.1/weights.bin",
            "https://192.168.1.2/weights.bin",
            "https://[::1]/weights.bin"
        ] {
            var local = descriptor(path: "weights.bin")
            local.artifacts[0].remoteURL = URL(string: privateURL)!
            do {
                _ = try await manager.install(local)
                Issue.record("A private-network model URL was accepted: \(privateURL)")
            } catch let error as ModelDownloadError {
                guard case .unsupportedURL = error else {
                    Issue.record("Unexpected error for \(privateURL): \(error)")
                    continue
                }
            }
        }

        var missingChecksum = descriptor(path: "weights.bin")
        missingChecksum.artifacts[0].sha256 = nil
        do {
            _ = try await manager.install(missingChecksum)
            Issue.record("A descriptor without a checksum was accepted")
        } catch let error as ModelDownloadError {
            guard case .invalidDescriptor = error else { Issue.record("Unexpected error: \(error)"); return }
        }

        var duplicate = descriptor(path: "Weights.bin")
        duplicate.artifacts.append(
            ModelArtifact(
                relativePath: "weights.bin",
                remoteURL: URL(string: "https://example.invalid/other")!,
                sha256: String(repeating: "0", count: 64),
                approximateBytes: 1
            )
        )
        do {
            _ = try await manager.install(duplicate)
            Issue.record("Case-folded duplicate artifact paths were accepted")
        } catch let error as ModelDownloadError {
            guard case .invalidDescriptor = error else { Issue.record("Unexpected error: \(error)"); return }
        }
    }

    @Test("Oversized downloads are rejected and staging data is removed")
    func oversizedDownloadIsCleanedUp() async throws {
        MockModelURLProtocol.configure(data: Data(repeating: 0x41, count: 2_048))
        let session = mockSession()
        defer { session.invalidateAndCancel() }
        let root = try temporaryDirectory(named: "ModelOversize")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelDownloadManager(
            rootDirectory: root,
            session: session,
            limits: ModelDownloadLimits(
                maximumArtifactCount: 4,
                maximumArtifactBytes: 1_024,
                maximumModelBytes: 4_096,
                freeSpaceReserveBytes: 0
            )
        )
        let artifact = ModelArtifact(
            relativePath: "weights.bin",
            remoteURL: URL(string: "https://models.invalid/weights.bin")!,
            sha256: String(repeating: "0", count: 64),
            approximateBytes: 1
        )
        let model = baseDescriptor(artifacts: [artifact])

        await #expect(throws: ModelDownloadError.downloadTooLarge(path: "weights.bin", maximum: 1_024)) {
            try await manager.install(model)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(leftovers.isEmpty)
    }

    @Test("Checksum failure preserves the previously committed model")
    func checksumFailurePreservesInstalledModel() async throws {
        let firstData = Data("first model".utf8)
        MockModelURLProtocol.configure(data: firstData)
        let session = mockSession()
        defer { session.invalidateAndCancel() }
        let root = try temporaryDirectory(named: "ModelAtomic")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelDownloadManager(
            rootDirectory: root,
            session: session,
            limits: ModelDownloadLimits(
                maximumArtifactCount: 4,
                maximumArtifactBytes: 1_024 * 1_024,
                maximumModelBytes: 2 * 1_024 * 1_024,
                freeSpaceReserveBytes: 0
            )
        )

        var first = descriptor(path: "weights.bin", data: firstData)
        first.version = "1"
        _ = try await manager.install(first)

        MockModelURLProtocol.configure(data: Data("corrupt replacement".utf8))
        var replacement = descriptor(path: "weights.bin", data: Data("expected replacement".utf8))
        replacement.version = "2"
        await #expect(throws: ModelDownloadError.checksumMismatch(path: "weights.bin")) {
            try await manager.install(replacement)
        }

        let installed = try await manager.installedModel(id: "test-model")
        #expect(installed?.descriptor.version == "1")
        let installedData = try Data(contentsOf: root.appendingPathComponent("test-model/weights.bin"))
        #expect(installedData == firstData)

        let replacementData = Data("expected replacement".utf8)
        MockModelURLProtocol.configure(data: replacementData)
        _ = try await manager.install(replacement)
        let replaced = try await manager.installedModel(id: "test-model")
        #expect(replaced?.descriptor.version == "2")
        #expect(try Data(contentsOf: root.appendingPathComponent("test-model/weights.bin")) == replacementData)

        let hiddenStaging = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".download-") || $0.hasPrefix(".rollback-") }
        #expect(hiddenStaging.isEmpty)
    }

    private func temporaryDirectory(named suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Notes\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func descriptor(path: String, data: Data = Data("model".utf8)) -> ModelDescriptor {
        baseDescriptor(
            artifacts: [
                ModelArtifact(
                    relativePath: path,
                    remoteURL: URL(string: "https://models.invalid/weights.bin")!,
                    sha256: sha256(data),
                    approximateBytes: Int64(max(1, data.count))
                )
            ]
        )
    }

    private func baseDescriptor(artifacts: [ModelArtifact]) -> ModelDescriptor {
        ModelDescriptor(
            id: "test-model",
            displayName: "Test Model",
            version: "1",
            licenseName: "Test License",
            licenseURL: URL(string: "https://example.invalid/license")!,
            artifacts: artifacts
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockModelURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockModelURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseData = Data()

    static func configure(data: Data) {
        lock.lock()
        responseData = data
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data: Data
        Self.lock.lock()
        data = Self.responseData
        Self.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(data.count)]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
