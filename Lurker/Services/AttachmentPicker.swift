// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
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
        // ⚠⚠ The list lives in `UploadContentTypes`, and it is the whole of what Files will let
        // you choose: an absent type is GREYED OUT with no "All Files" escape, so an omission
        // reads as "Lurker can't send this" (#125).
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: UploadContentTypes.forOpening)
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
            // Cancellable, and that matters twice over. This is the long silent stretch of the
            // pick — an iCloud video is a download — so a cancel here has to actually stop
            // rather than run the batch out. And it's the one step whose completion is not
            // ours to guarantee: it comes from an out-of-process picker extension, which can
            // be jetsammed mid-load. Without a way out, that would hang the run forever and,
            // because the task never ends, leave the paperclip dead until the app relaunched.
            // `Handoff` resumes on cancel WITHOUT waiting for the provider, so the way out
            // exists even when the callback never comes.
            let handoff = Handoff()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard handoff.begin(continuation) else { return }
                    // The vended URL is valid only inside this closure, so the move has to
                    // happen there and the handoff carries the staged result, not the URL.
                    let progress = provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, error in
                        guard let url else {
                            handoff.finish(
                                .failure(.failed(error?.localizedDescription ?? "Couldn't read the file."))
                            )
                            return
                        }
                        handoff.finish(
                            copy(
                                url, isVideo: isVideo, allowMove: true,
                                fallbackExtension: isVideo ? "mov" : "jpg"))
                    }
                    handoff.track(progress)
                }
            } onCancel: {
                handoff.cancel()
            }
        case .document(let url, let isVideo):
            return await withCheckedContinuation { continuation in
                // Off main: the copy is large, and the security scope must stay held across
                // it — so acquire the scope inside the background block, not on the way in.
                DispatchQueue.global(qos: .userInitiated).async {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    continuation.resume(
                        returning: copy(
                            url, isVideo: isVideo, allowMove: false, fallbackExtension: nil))
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
    /// `fallbackExtension` names what an extensionless source almost certainly is — and is nil
    /// when nothing here knows.
    ///
    /// ⚠⚠ It used to be `isVideo ? "mov" : "jpg"`, reading a two-way flag as if "not video" meant
    /// "image". That was true while Files only offered images and movies; now that it offers text
    /// (#125), an extensionless pick would be copied to `…​.jpg` and claimed as `image/jpeg` — and
    /// the server reads an upload's dialect from the filename FIRST and the claim second, so a
    /// confident wrong claim is worse than none. A photo-library item genuinely is one or the
    /// other and still says so; a document says nothing and takes `application/octet-stream`,
    /// which `classifyUpload` overrules from the bytes anyway.
    private nonisolated static func copy(
        _ source: URL, isVideo: Bool, allowMove: Bool, fallbackExtension: String?
    ) -> Result<Picked, PickError> {
        let ext = source.pathExtension.isEmpty ? (fallbackExtension ?? "") : source.pathExtension
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                ext.isEmpty
                    ? "lurker-attach-\(UUID().uuidString)"
                    : "lurker-attach-\(UUID().uuidString).\(ext)")
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
        let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        // ⚠⚠ A text type with no registered mime claims `text/plain`, NOT octet-stream, and the
        // difference is a misclassification with teeth. Plenty of what `.text` offers has no
        // `preferredMIMEType` at all — `.log`, `.sh`, `.c`, `.swift` all return nil — and the
        // server exempts a claim from its SVG probe only when the claim is already a text dialect.
        // So an octet-stream claim on a shell script that happens to contain `<svg ` in its first
        // kilobyte is classified `image/svg+xml`: a 415 on hosted, and on self-host a file stored
        // and served as an ACTIVE SVG rather than as the text it is. Claiming `text/plain` keeps
        // it on the text path, where `dialectFromFilename` still gets the last word.
        let mime = type?.preferredMIMEType
            ?? (type?.conforms(to: .text) == true
                ? "text/plain"
                : (isVideo ? "video/mp4" : "application/octet-stream"))
        // ⚠ The filename carries the inferred extension too, when one was inferred. Having the
        // temp file and the claim say `.jpg` while the name we upload says nothing is the two
        // halves disagreeing, and the name is the half that travels: the server reads an upload's
        // dialect from the FILENAME first, and the transcode path rewrites extensions by string
        // surgery on it. When the source named itself this changes nothing, which is every
        // ordinary pick.
        let filename =
            source.pathExtension.isEmpty && !ext.isEmpty
            ? "\(source.lastPathComponent).\(ext)"
            : source.lastPathComponent
        return .success(Picked(url: dest, filename: filename, mime: mime, isVideo: isVideo))
    }

    /// Resume-once plumbing for a staging step that can finish two ways — the provider calling
    /// back, or the task being cancelled — from two different threads.
    ///
    /// Resuming a `CheckedContinuation` twice traps, and every ordering here is possible: the
    /// task can already be cancelled before the load starts, cancellation can land between
    /// starting the load and getting the `Progress` handle back, and a cancelled load still
    /// calls its completion afterwards. So the lock guards one decision — who got here first —
    /// and everything else is a no-op.
    ///
    /// Cancelling resumes immediately rather than waiting for the provider to acknowledge it,
    /// which is what bounds the case where the provider never speaks again.
    /// `nonisolated` is load-bearing: the target's default actor isolation would otherwise
    /// make this main-actor, and every one of its callers is off it — a provider callback on
    /// its own queue, and a cancellation handler that runs wherever the cancel came from. The
    /// lock is what makes it safe, not an actor.
    private nonisolated final class Handoff: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<Picked, PickError>, Never>?
        private var progress: Progress?
        private var cancelled = false

        /// Adopt the continuation. Answers false when the task was *already* cancelled, having
        /// resumed it — the caller must not start any work.
        func begin(_ continuation: CheckedContinuation<Result<Picked, PickError>, Never>) -> Bool {
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(returning: .failure(.cancelled))
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        /// Hand over the load's `Progress` so a cancel can stop it. If the cancel already
        /// happened, stop it now — otherwise a load started microseconds before would run to
        /// completion with nobody waiting for it.
        func track(_ progress: Progress) {
            lock.lock()
            if cancelled {
                lock.unlock()
                progress.cancel()
                return
            }
            self.progress = progress
            lock.unlock()
        }

        func finish(_ result: Result<Picked, PickError>) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: result)
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let running = progress
            let waiting = continuation
            continuation = nil
            lock.unlock()
            running?.cancel()
            waiting?.resume(returning: .failure(.cancelled))
        }
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
