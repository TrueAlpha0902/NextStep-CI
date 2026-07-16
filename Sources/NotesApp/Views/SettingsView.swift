import NotesServices
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @AppStorage("editor.fingerDrawing") private var fingerDrawingEnabled = false
    @AppStorage("editor.fingerDrawing.phone") private var phoneFingerDrawingEnabled = true
    @StateObject private var localModelLibrary = LocalModelLibrary()
    @State private var showsFolderPicker = false
    @State private var showsBackupFolderPicker = false
    @State private var showsLocalModelFolderPicker = false
    @State private var pendingRestore: BackupSnapshot?
    @State private var pendingModelRemoval: InstalledModel?
    @State private var modelOperationTask: Task<Void, Never>?
    @State private var modelOperationToken: UUID?

    var body: some View {
        Form {
            Section("Library location") {
                LabeledContent(
                    "Current folder",
                    value: CurrentDevicePresentation.libraryRootDescription(
                        appModel.rootDescription
                    )
                )
                Button {
                    showsFolderPicker = true
                } label: {
                    Label("Choose Files folder", systemImage: "folder.badge.gearshape")
                }
                Button {
                    Task { await appModel.useRootDirectory(nil) }
                } label: {
                    Label {
                        Text(verbatim: CurrentDevicePresentation.localized(
                            "Use On My iPad"
                        ))
                    } icon: {
                        Image(systemName: CurrentDevicePresentation.isPhone
                              ? "iphone"
                              : "ipad")
                    }
                }
            }

            Section("Input") {
                Toggle(isOn: fingerDrawingPreference) {
                    Label("Draw with finger", systemImage: "hand.draw")
                }
                Text("Keep this off for Apple Pencil palm rejection. If an eiP or other compatible stylus is treated as touch and does not draw, turn it on; then use two fingers to pan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Backup folder", value: appModel.backupFolderDescription)

                Button {
                    showsBackupFolderPicker = true
                } label: {
                    Label("Choose backup folder", systemImage: "externaldrive.badge.plus")
                }

                if appModel.isBackupConfigured {
                    Button {
                        Task { await appModel.createBackup() }
                    } label: {
                        Label("Back up now", systemImage: "externaldrive.badge.checkmark")
                    }
                    .disabled(appModel.isBackupOperationRunning)

                    Button {
                        Task { await appModel.refreshBackupSnapshots() }
                    } label: {
                        Label("Refresh backup history", systemImage: "arrow.clockwise")
                    }
                    .disabled(appModel.isBackupOperationRunning)

                    if appModel.isBackupOperationRunning {
                        ProgressView("Working on backup…")
                    } else if appModel.backupSnapshots.isEmpty {
                        Text("No backups found in this folder.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(appModel.backupSnapshots.prefix(10))) { snapshot in
                            Button {
                                pendingRestore = snapshot
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "externaldrive.fill.badge.checkmark")
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(snapshot.createdAt, format: .dateTime.year().month().day().hour().minute())
                                            .foregroundStyle(.primary)
                                        HStack(spacing: 4) {
                                            Text(verbatim: "\(snapshot.notebookNames.count)")
                                            Text("notebooks in backup")
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.counterclockwise")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(appModel.isBackupOperationRunning)
                        }
                    }

                    Button(role: .destructive) {
                        appModel.clearBackupDirectory()
                    } label: {
                        Label("Forget backup folder", systemImage: "externaldrive.badge.xmark")
                    }
                    .disabled(appModel.isBackupOperationRunning)
                }
            } header: {
                Text("Backup and restore")
            } footer: {
                Text("Backups contain verified notebook packages. Restore never overwrites an existing notebook identity; choose an empty library folder when recovering a full library. Trash and cover appearance are not included yet.")
            }

            Section {
                Button {
                    showsLocalModelFolderPicker = true
                } label: {
                    Label("Import local model folder", systemImage: "square.and.arrow.down")
                }
                .disabled(localModelLibrary.isWorking)
                .accessibilityIdentifier("settings.local-models.import")

                Button {
                    startModelOperation {
                        await localModelLibrary.refresh()
                    }
                } label: {
                    Label("Verify installed models", systemImage: "checkmark.shield")
                }
                .disabled(localModelLibrary.isWorking)
                .accessibilityIdentifier("settings.local-models.verify")

                if localModelLibrary.isWorking {
                    ProgressView(localModelProgressLabel)
                        .accessibilityIdentifier("settings.local-models.progress")
                } else if localModelLibrary.models.isEmpty {
                    ContentUnavailableView(
                        "No local models installed",
                        systemImage: "cpu",
                        description: Text("Choose a model folder that contains model.json and its listed files.")
                    )
                    .accessibilityIdentifier("settings.local-models.empty")
                } else {
                    ForEach(localModelLibrary.models) { model in
                        localModelRow(model)
                    }
                }

                if let verifiedAt = localModelLibrary.lastVerifiedAt,
                   !localModelLibrary.isWorking {
                    LabeledContent("Last verified") {
                        Text(verifiedAt, format: .dateTime.year().month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            } header: {
                Text("On-device models")
            } footer: {
                Text("NextStep never uploads imported model files and does not include a paid or remote model catalog. Import reads only files listed in model.json, enforces storage limits, and verifies every SHA-256 checksum. This build manages verified model artifacts; on-device text generation is not connected yet.")
            }

            Section("Diagnostics") {
                LabeledContent("Notes", value: "\(appModel.notebooks.count)")
                LabeledContent {
                    Text(verbatim: UIDevice.current.systemVersion)
                } label: {
                    Text(verbatim: CurrentDevicePresentation.operatingSystemName)
                }
                LabeledContent("Storage format", value: ".notepkg")
                LabeledContent("Drawing engine", value: "PencilKit")
                LabeledContent("PDF engine", value: "PDFKit")
                LabeledContent("App version", value: appVersion)
            }

            Section("Privacy") {
                Label("Notes stay in your chosen Files folder.", systemImage: "lock.shield")
                Text("This build does not upload note content or require an account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("App", value: "NextStep")
                Text(verbatim: CurrentDevicePresentation.localized(
                    "An original, local-first iPad notebook built with Apple frameworks."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showsFolderPicker) {
            DocumentPicker(mode: .folder) { urls in
                showsFolderPicker = false
                guard let url = urls.first else { return }
                Task { await appModel.useRootDirectory(url) }
            } onCancel: {
                showsFolderPicker = false
            }
        }
        .sheet(isPresented: $showsBackupFolderPicker) {
            DocumentPicker(mode: .folder) { urls in
                showsBackupFolderPicker = false
                guard let url = urls.first else { return }
                Task { await appModel.useBackupDirectory(url) }
            } onCancel: {
                showsBackupFolderPicker = false
            }
        }
        .sheet(isPresented: $showsLocalModelFolderPicker) {
            DocumentPicker(mode: .folder) { urls in
                showsLocalModelFolderPicker = false
                guard let url = urls.first else { return }
                startModelOperation {
                    await localModelLibrary.importPackage(from: url)
                }
            } onCancel: {
                showsLocalModelFolderPicker = false
            }
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: restoreConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Cancel", role: .cancel) {
                pendingRestore = nil
            }
            Button("Restore", role: .destructive) {
                guard let snapshot = pendingRestore else { return }
                pendingRestore = nil
                Task { await appModel.restoreBackup(snapshot) }
            }
        } message: {
            Text("NextStep will add every notebook from this snapshot. If any notebook identity already exists, nothing is restored.")
        }
        .confirmationDialog(
            "Remove this local model?",
            isPresented: modelRemovalConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Cancel", role: .cancel) {
                pendingModelRemoval = nil
            }
            Button("Remove Model", role: .destructive) {
                guard let model = pendingModelRemoval else { return }
                pendingModelRemoval = nil
                startModelOperation {
                    await localModelLibrary.removeModel(id: model.id)
                }
            }
        } message: {
            Text("The verified model files will be deleted from NextStep. Your notebooks are not affected.")
        }
        .alert(
            "Local model problem",
            isPresented: localModelFailureBinding
        ) {
            Button("OK") {
                localModelLibrary.clearFailure()
            }
        } message: {
            Text(localModelLibrary.failureMessage ?? "")
        }
        .task {
            await appModel.refreshBackupSnapshots()
            await localModelLibrary.refresh()
        }
        .onDisappear {
            modelOperationToken = nil
            modelOperationTask?.cancel()
            modelOperationTask = nil
        }
        .accessibilityIdentifier("settings.form")
    }

    private var fingerDrawingPreference: Binding<Bool> {
        Binding(
            get: {
                CurrentDevicePresentation.isPhone
                    ? phoneFingerDrawingEnabled
                    : fingerDrawingEnabled
            },
            set: { isEnabled in
                if CurrentDevicePresentation.isPhone {
                    phoneFingerDrawingEnabled = isEnabled
                } else {
                    fingerDrawingEnabled = isEnabled
                }
            }
        )
    }

    private var appVersion: String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
        return "\(version) (\(build))"
    }

    private var restoreConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingRestore != nil },
            set: { if !$0 { pendingRestore = nil } }
        )
    }

    private var modelRemovalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingModelRemoval != nil },
            set: { if !$0 { pendingModelRemoval = nil } }
        )
    }

    private var localModelFailureBinding: Binding<Bool> {
        Binding(
            get: { localModelLibrary.failureMessage != nil },
            set: { if !$0 { localModelLibrary.clearFailure() } }
        )
    }

    private var localModelProgressLabel: LocalizedStringKey {
        switch localModelLibrary.operation {
        case .idle, .refreshing:
            "Verifying local models…"
        case .importing:
            "Importing and verifying local model…"
        case .removing:
            "Removing local model…"
        }
    }

    @ViewBuilder
    private func localModelRow(_ model: InstalledModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.descriptor.displayName)
                        .font(.headline)
                    Text(
                        String(
                            format: String(localized: "Version %@ • declared %@"),
                            model.descriptor.version,
                            formattedByteCount(model.descriptor.approximateBytes)
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Verified")
            }

            HStack(spacing: 12) {
                Link(destination: model.descriptor.licenseURL) {
                    Label(model.descriptor.licenseName, systemImage: "doc.text")
                }
                .font(.caption)

                Spacer(minLength: 12)

                Button(role: .destructive) {
                    pendingModelRemoval = model
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .font(.caption)
                .disabled(localModelLibrary.isWorking)
                .accessibilityIdentifier("settings.local-models.remove.\(model.id)")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.local-models.model.\(model.id)")
    }

    private func formattedByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private func startModelOperation(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        let previousTask = modelOperationTask
        previousTask?.cancel()
        let token = UUID()
        modelOperationToken = token
        modelOperationTask = Task { @MainActor in
            await previousTask?.value
            guard !Task.isCancelled else {
                if modelOperationToken == token {
                    modelOperationTask = nil
                    modelOperationToken = nil
                }
                return
            }
            await operation()
            if modelOperationToken == token {
                modelOperationTask = nil
                modelOperationToken = nil
            }
        }
    }
}
