// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Presents the two attachment sources — the photo library (`PHPickerViewController`, which
/// runs out of process and so needs *no* photo-library permission prompt) and the file
/// browser (`UIDocumentPickerViewController`) — and hands back what the user chose. Sharing
/// from other apps via the system share sheet is a separate, later card.
///
/// **The pick and the copy are deliberately separate steps.** Choosing returns `Source`
/// handles immediately, and each one is staged to a temp file only when its turn comes
/// (`stage(_:)`), immediately before that file uploads. Both sources are multi-select, and
/// staging the whole selection up front would put *all* of it on disk at once — fifteen 4K
/// videos is ~10 GB copied into `NSTemporaryDirectory()` before a single byte uploads, which
/// ends in a failed copy or a jetsam. Staged one at a time and deleted after each upload,
/// peak temp usage is one file no matter how many were picked.
///
/// It also puts the whole run inside the caller's cancellable task: a cancel during the
/// third file's iCloud download stops the remaining twelve, which it could not do while the
/// copying happened in here before the upload task existed.
///
/// Copying at all is deliberate: both pickers vend URLs valid only briefly (a scoped item
/// rep, a security-scoped document), so the byte-for-byte copy is what the upload reads.
@MainActor
final class AttachmentPicker: NSObject {

    /// One chosen item, **not yet on disk**. Holding the picker's own handle rather than a
    /// file is what lets the caller pay for one copy at a time; the handles stay valid after
    /// the picker is dismissed.
    enum Source {
        case photo(NSItemProvider, typeID: String, isVideo: Bool)
        case document(URL, isVideo: Bool)
        /// Something the picker offered that we can't read — kept in the list rather than
        /// filtered out of it, so it fails loudly at its turn and is counted with the rest.
        /// Dropping it here instead would make the batch quietly smaller than the pick.
        case unsupported
        /// Already staged by the caller (a pasted image, written straight to a temp file).
        /// Passes through `stage` untouched so one path covers every entry point.
        case ready(Picked)
    }

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

    private weak var presenter: UIViewController?
    private var completion: ((Result<[Source], PickError>) -> Void)?

    init(presenter: UIViewController) {
        self.presenter = presenter
    }

    // MARK: - Entry points

    func pickFromPhotoLibrary(completion: @escaping (Result<[Source], PickError>) -> Void) {
        self.completion = completion
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        // Unlimited, deliberately. A ceiling here would be an arbitrary cap on something that
        // costs nothing to allow: files stage and upload one at a time, peak disk is one file,
        // the readout says which of how many, and cancel stops the rest — so picking too many
        // is recoverable in a tap rather than something to pre-empt with a number.
        config.selectionLimit = 0
        // `.current` returns the asset as it already exists (HEIC/HEVC), skipping the
        // picker's own transcode — faster, and the bytes the server/our compressor expect.
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    func pickFromFiles(completion: @escaping (Result<[Source], PickError>) -> Void) {
        self.completion = completion
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image, .movie])
        picker.allowsMultipleSelection = true
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    // MARK: - Staging

    /// Copy one source into a temp file the caller owns and must delete.
    ///
    /// Static, because it outlives the picker: the caller drops its reference the moment the
    /// pick is delivered, and staging happens across the whole upload run after that.
    ///
    /// The work never touches main — `loadFileRepresentation` calls back on its own queue,
    /// and the document copy is dispatched to a global one — but this stays main-actor so the
    /// `Source` handles never have to cross an isolation boundary.
    static func stage(_ source: Source) async -> Result<Picked, PickError> {
        switch source {
        case .ready(let picked):
            return .success(picked)
        case .unsupported:
            return .failure(.failed("That item can't be uploaded."))
        case .photo(let provider, let typeID, let isVideo):
            return await withCheckedContinuation { continuation in
                // The vended URL is valid only inside this closure, so the move has to happen
                // there and the continuation resumes with the staged result, not the URL.
                provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, error in
                    guard let url else {
                        continuation.resume(
                            returning: .failure(.failed(error?.localizedDescription ?? "Couldn't read the file."))
                        )
                        return
                    }
                    continuation.resume(returning: copy(url, isVideo: isVideo, allowMove: true))
                }
            }
        case .document(let url, let isVideo):
            return await withCheckedContinuation { continuation in
                // Off main: the copy is large, and the security scope must stay held across
                // it — so acquire the scope inside the background block, not on the way in.
                DispatchQueue.global(qos: .userInitiated).async {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    continuation.resume(returning: copy(url, isVideo: isVideo, allowMove: false))
                }
            }
        }
    }

    /// The copy itself, synchronous because `loadFileRepresentation`'s URL dies when its
    /// closure returns — this cannot be something the caller awaits and does afterwards.
    ///
    /// `allowMove` is the difference between the two sources. The photo picker hands us an
    /// ephemeral temp file it's about to delete anyway, so we *move* it (a rename — instant)
    /// rather than copy a second full 200 MB behind the picker's own export. A document is
    /// the user's real file (security-scoped, possibly read-only in iCloud), so it must be
    /// copied.
    private nonisolated static func copy(
        _ source: URL, isVideo: Bool, allowMove: Bool
    ) -> Result<Picked, PickError> {
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
            return .failure(.failed(error.localizedDescription))
        }
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType
            ?? (isVideo ? "video/mp4" : "application/octet-stream")
        return .success(Picked(url: dest, filename: source.lastPathComponent, mime: mime, isVideo: isVideo))
    }

    private func deliver(_ result: Result<[Source], PickError>) {
        let done = completion
        completion = nil
        done?(result)
    }
}

// MARK: - Photo library

extension AttachmentPicker: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else {
            deliver(.failure(.cancelled))
            return
        }
        // Video vs image decides both the type identifier we load and whether we compress.
        // Resolved per item: one pick can mix them freely. Note this maps rather than filters,
        // so a result we can't load stays in the list as `.unsupported` and is reported at its
        // turn instead of silently shrinking the batch.
        deliver(.success(results.map { result in
            let provider = result.itemProvider
            let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            let typeID = isVideo ? UTType.movie.identifier : UTType.image.identifier
            guard provider.hasItemConformingToTypeIdentifier(typeID) else { return .unsupported }
            return .photo(provider, typeID: typeID, isVideo: isVideo)
        }))
    }
}

// MARK: - Files

extension AttachmentPicker: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else {
            deliver(.failure(.cancelled))
            return
        }
        deliver(.success(urls.map { url in
            .document(url, isVideo: (UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie)) ?? false)
        }))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        deliver(.failure(.cancelled))
    }
}
