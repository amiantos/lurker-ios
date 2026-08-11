// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Presents the two attachment sources — the photo library (`PHPickerViewController`, which
/// runs out of process and so needs *no* photo-library permission prompt) and the file
/// browser (`UIDocumentPickerViewController`) — and hands back temp-file copies of whatever
/// the user picked. Copying is deliberate: both pickers vend URLs that are valid only
/// briefly (a scoped item rep, a security-scoped document), so the byte-for-byte copy is
/// what the upload actually reads. Sharing from other apps via the system share sheet is a
/// separate, later card.
///
/// Both sources are multi-select (#47 follow-up). Staging runs one item at a time rather than
/// concurrently: these are hundreds of megabytes of copies and iCloud downloads, and doing
/// them at once would multiply peak disk and memory for no wall-clock win on a phone. The
/// result preserves pick order, because that's the order the URLs will land in the composer.
@MainActor
final class AttachmentPicker: NSObject {

    /// What one pick produced: the items that staged, in pick order, and how many didn't.
    ///
    /// A partial failure is *reported*, not swallowed. Quietly uploading three of the five
    /// files someone selected reads as data loss, and the two that vanished are precisely the
    /// ones they would never think to check for.
    struct Batch {
        let items: [Picked]
        let failed: Int
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

    /// Fired as each item begins staging — before the export/copy, which for a large or
    /// iCloud-resident video is a multi-second silent stretch. The owner uses it to raise a
    /// "Preparing…" readout so that stretch isn't a dead pause. Carries the 1-based position
    /// and the total, so a batch can say which of how many it's on rather than sitting on one
    /// unchanging label for a minute.
    var onPreparing: ((_ index: Int, _ total: Int) -> Void)?

    private weak var presenter: UIViewController?
    private var completion: ((Result<Batch, PickError>) -> Void)?

    init(presenter: UIViewController) {
        self.presenter = presenter
    }

    // MARK: - Entry points

    func pickFromPhotoLibrary(completion: @escaping (Result<Batch, PickError>) -> Void) {
        self.completion = completion
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        // Unlimited, deliberately. A ceiling here would be an arbitrary cap on something that
        // costs nothing to allow: uploads run one at a time, each is its own request, the
        // readout says which of how many, and cancel stops the rest — so picking too many is
        // recoverable in a tap rather than something to pre-empt with a number.
        config.selectionLimit = 0
        // `.current` returns the asset as it already exists (HEIC/HEVC), skipping the
        // picker's own transcode — faster, and the bytes the server/our compressor expect.
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    func pickFromFiles(completion: @escaping (Result<Batch, PickError>) -> Void) {
        self.completion = completion
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image, .movie])
        picker.allowsMultipleSelection = true
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    // MARK: - Shared file prep

    /// Stage one picked source into our own temp file.
    ///
    /// **Synchronous, and returns rather than delivering.** `loadFileRepresentation` vends a
    /// URL that is valid only for the duration of its closure, so the copy has to complete
    /// before that closure returns — it can't be something the caller awaits and performs
    /// afterwards. Callers invoke this from a background queue: the transfer can be a couple
    /// hundred MB and must never touch main.
    ///
    /// `allowMove` is the difference between the two sources. The photo picker hands us an
    /// ephemeral temp file it's about to delete anyway, so we *move* it (a rename — instant)
    /// rather than copy a second full 200 MB behind the picker's own export. A document is
    /// the user's real file (security-scoped, possibly read-only in iCloud), so it must be
    /// copied.
    private nonisolated func stage(_ source: URL, isVideo: Bool, allowMove: Bool) -> Result<Picked, PickError> {
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

    /// Collects staged items in pick order and reports the batch. One item's failure costs
    /// only that item — the rest of a ten-file pick shouldn't be lost because the third one
    /// was a corrupt asset — but the count travels with the result so the owner can say so.
    private func collect(
        count: Int,
        stageItem: (Int) async -> Result<Picked, PickError>
    ) async {
        var staged: [Picked] = []
        var failed = 0
        var firstMessage: String?
        for index in 0..<count {
            onPreparing?(index + 1, count)
            switch await stageItem(index) {
            case .success(let picked):
                staged.append(picked)
            case .failure(let error):
                // Counted whatever the shape of the error, so the tally can't drift from
                // reality — only the *message* depends on there being one to quote.
                failed += 1
                if case .failed(let message) = error, firstMessage == nil { firstMessage = message }
            }
        }
        if staged.isEmpty {
            // Nothing survived: this is an outright failure, not a batch with holes in it.
            deliver(.failure(firstMessage.map { PickError.failed($0) } ?? .cancelled))
        } else {
            deliver(.success(Batch(items: staged, failed: failed)))
        }
    }

    /// Stage one document off the main actor, holding its security scope across the copy —
    /// acquired inside the background block, not on the calling thread, because the scope has
    /// to be held for the duration of the transfer.
    private nonisolated func stageDocument(_ url: URL, isVideo: Bool) async -> Result<Picked, PickError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                continuation.resume(returning: self.stage(url, isVideo: isVideo, allowMove: false))
            }
        }
    }

    private func deliver(_ result: Result<Batch, PickError>) {
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
        // Resolved per item: one pick can mix them freely.
        let loadable = results.compactMap { result -> (provider: NSItemProvider, typeID: String, isVideo: Bool)? in
            let provider = result.itemProvider
            let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            let typeID = isVideo ? UTType.movie.identifier : UTType.image.identifier
            guard provider.hasItemConformingToTypeIdentifier(typeID) else { return nil }
            return (provider, typeID, isVideo)
        }
        guard !loadable.isEmpty else {
            deliver(.failure(.failed("Those items can't be uploaded.")))
            return
        }
        Task {
            await collect(count: loadable.count) { index in
                let item = loadable[index]
                return await withCheckedContinuation { continuation in
                    // The vended URL is valid only inside this closure, so the move happens
                    // here and the continuation resumes with the staged result, not the URL.
                    item.provider.loadFileRepresentation(forTypeIdentifier: item.typeID) { url, error in
                        guard let url else {
                            continuation.resume(
                                returning: .failure(.failed(error?.localizedDescription ?? "Couldn't read the file."))
                            )
                            return
                        }
                        continuation.resume(returning: self.stage(url, isVideo: item.isVideo, allowMove: true))
                    }
                }
            }
        }
    }
}

// MARK: - Files

extension AttachmentPicker: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else {
            deliver(.failure(.cancelled))
            return
        }
        Task {
            await collect(count: urls.count) { index in
                let url = urls[index]
                let isVideo = (UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie)) ?? false
                return await stageDocument(url, isVideo: isVideo)
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        deliver(.failure(.cancelled))
    }
}
