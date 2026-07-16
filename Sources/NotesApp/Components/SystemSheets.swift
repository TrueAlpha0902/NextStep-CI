import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
enum CurrentDevicePresentation {
    static var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    static var deviceName: String {
        isPhone ? "iPhone" : "iPad"
    }

    static var operatingSystemName: String {
        isPhone ? "iOS" : "iPadOS"
    }

    /// Reuses the existing localized iPad copy while substituting Apple's
    /// non-localized product name when the same screen runs on iPhone.
    static func localized(_ resource: LocalizedStringResource) -> String {
        String(localized: resource)
            .replacingOccurrences(of: "iPad", with: deviceName)
    }

    /// Adapts only the app-owned default location label. User-selected folder
    /// names are returned verbatim, even when their name contains "iPad".
    static func libraryRootDescription(_ value: String) -> String {
        guard isPhone,
              value == String(localized: "On My iPad") else {
            return value
        }
        return localized("On My iPad")
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    enum Mode: Equatable {
        case folder
        case importableDocuments
    }

    let mode: Mode
    let onPick: ([URL]) -> Void
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let contentTypes: [UTType]
        let asCopy: Bool
        switch mode {
        case .folder:
            contentTypes = [.folder]
            asCopy = false
        case .importableDocuments:
            contentTypes = [.notesNotebook, .pdf, .jpeg, .png]
            asCopy = true
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: asCopy)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = mode == .importableDocuments
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: DocumentPicker

        init(parent: DocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

private extension UTType {
    static let notesNotebook = UTType(exportedAs: "com.speci.localnotes.notepkg")
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
