// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Presents the two attachment sources — the photo library (`PHPickerViewController`, which
/// runs out of process and so needs *no* photo-library permission prompt) and the file
/// browser (`UIDocumentPickerViewController`) — and hands back a temp-file copy of whatever
/// the user picked. Copying is deliberate: both pickers vend URLs that are valid only
/// briefly (a scoped item rep, a security-scoped document), so the byte-for-byte copy is
/// what the upload actually reads. Sharing from other apps via the system share sheet is a
/// separate, later card.
@MainActor
final class AttachmentPicker: NSObject {

    /// A picked file, copied somewhere the caller owns and must delete when done.
    struct Picked {
        let url: URL
        let filename: String
        let mime: String
        /// True for video, the one class we compress on-device before uploading. Images and
        /// audio pass straight through (the server re-encodes images; audio is already small).
        let isVideo: Bool
    }

    enum PickError: Error {
        case cancelled
        case failed(String)
    }

    /// Fired the instant an item is chosen — before the export/copy, which for a large or
    /// iCloud-resident video is a multi-second silent stretch. The owner uses it to raise a
    /// "Preparing…" readout so that stretch isn't a dead pause.
    var onPreparing: (() -> Void)?

    private weak var presenter: UIViewController?
    private var completion: ((Result<Picked, PickError>) -> Void)?

    init(presenter: UIViewController) {
        self.presenter = presenter
    }

    // MARK: - Entry points

    func pickFromPhotoLibrary(completion: @escaping (Result<Picked, PickError>) -> Void) {
        self.completion = completion
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 1
        // `.current` returns the asset as it already exists (HEIC/HEVC), skipping the
        // picker's own transcode — faster, and the bytes the server/our compressor expect.
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    func pickFromFiles(completion: @escaping (Result<Picked, PickError>) -> Void) {
        self.completion = completion
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image, .movie])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    // MARK: - Shared file prep

    /// Stage a picked source into our own temp file and report it. Callers invoke this from a
    /// background queue — the transfer can be a couple hundred MB and must never touch main —
    /// and it hops back to the main actor to deliver the result.
    ///
    /// `allowMove` is the difference between the two sources. The photo picker hands us an
    /// ephemeral temp file it's about to delete anyway, so we *move* it (a rename — instant)
    /// rather than copy a second full 200 MB behind the picker's own export. A document is
    /// the user's real file (security-scoped, possibly read-only in iCloud), so it must be
    /// copied.
    private nonisolated func finish(copying source: URL, isVideo: Bool, allowMove: Bool) {
        let ext = source.pathExtension.isEmpty ? (isVideo ? "mov" : "jpg") : source.pathExtension
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lurker-attach-\(UUID().uuidString).\(ext)")
        do {
            if allowMove {
                // Move can fail across volumes; fall back to a copy so we never lose the pick.
                do { try FileManager.default.moveItem(at: source, to: dest) }
                catch { try FileManager.default.copyItem(at: source, to: dest) }
            } else {
                try FileManager.default.copyItem(at: source, to: dest)
            }
        } catch {
            deliver(.failure(.failed(error.localizedDescription)))
            return
        }
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType
            ?? (isVideo ? "video/mp4" : "application/octet-stream")
        deliver(.success(Picked(url: dest, filename: source.lastPathComponent, mime: mime, isVideo: isVideo)))
    }

    private nonisolated func deliver(_ result: Result<Picked, PickError>) {
        Task { @MainActor in
            let done = self.completion
            self.completion = nil
            done?(result)
        }
    }
}

// MARK: - Photo library

extension AttachmentPicker: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else {
            deliver(.failure(.cancelled))
            return
        }
        // Video vs image decides both the type identifier we load and whether we compress.
        let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
        let typeID = isVideo ? UTType.movie.identifier : UTType.image.identifier
        guard provider.hasItemConformingToTypeIdentifier(typeID) else {
            deliver(.failure(.failed("That item can't be uploaded.")))
            return
        }
        // An item is committed — the (possibly slow) export is about to run. Raise the readout.
        onPreparing?()
        // The vended URL is valid only inside this closure, so the move has to happen here.
        provider.loadFileRepresentation(forTypeIdentifier: typeID) { [weak self] url, error in
            guard let self else { return }
            guard let url else {
                self.deliver(.failure(.failed(error?.localizedDescription ?? "Couldn't read the file.")))
                return
            }
            self.finish(copying: url, isVideo: isVideo, allowMove: true)
        }
    }
}

// MARK: - Files

extension AttachmentPicker: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            deliver(.failure(.cancelled))
            return
        }
        let isVideo = (UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie)) ?? false
        onPreparing?()
        // Off main: the copy is large, and the security scope must stay held across it — so
        // acquire the scope inside the background block, not in this main-thread callback.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            self?.finish(copying: url, isVideo: isVideo, allowMove: false)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        deliver(.failure(.cancelled))
    }
}
