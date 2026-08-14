import SwiftUI
import UIKit

// Saving a finished report as a file the operator can find again.
//
// In:  a file URL inside the app's own Documents folder.
// Out: a copy wherever the operator points it — On My iPhone, iCloud Drive, a connected drive.
//
// Sharing was not enough: the ask was to put the txt on the device. This is the system's own save
// panel, so the file lands in a real folder rather than in whatever app the share sheet offers. The
// app's Documents folder is exposed to the Files app as well, so every report can also be picked up
// from Files › PayloadMeasure › StudyRuns without the app being involved at all.

struct DocumentExporter: UIViewControllerRepresentable {
    let url: URL
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            onFinish(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(false)
        }
    }
}
