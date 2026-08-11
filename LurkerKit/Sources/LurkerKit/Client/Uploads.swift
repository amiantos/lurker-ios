// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The upload contract, client-side. `POST /api/uploads` is multipart/form-data with a
/// `progressToken` field and an `image` file field (that field name is the server's, and
/// covers every content class — image, video, text — not just images). The server re-encodes
/// images, scrubs video metadata, and answers with the public URL of the stored object.
public enum Uploads {
    /// The largest request body we'll put on the wire, and the size the app's
    /// `VideoCompressor` shrinks video to fit under.
    ///
    /// This is NOT the uploader's own cap — the server enforces that, up to `MAX_CAP_MB`
    /// (200 MB) — it's the ceiling imposed by the CDN *in front of* the instance.
    /// app.lurker.chat is fronted by Cloudflare, whose request-body limit is 100 MB on every
    /// non-Enterprise plan; a larger body is rejected at the edge with a connection reset the
    /// client sees as `cannotParseResponse`, long before the server's own limit is consulted
    /// (confirmed: a 139 MB screen recording died exactly this way). We target comfortably
    /// under 100 MB to leave room for the multipart envelope and any edge accounting.
    ///
    /// ⚠ Hardcoded deliberately, for now. The correct fix is the server advertising its
    /// effective cap, so a self-hosted instance with no 100 MB CDN limit isn't compressed
    /// down to this number needlessly — tracked as a follow-up. Until then a Cloudflare-safe
    /// default is the right call: most instances (hosted, and self-hosts behind Cloudflare/a
    /// tunnel) share this exact ceiling.
    public static let maxBytes = 90 * 1024 * 1024
}

/// What the server returns on a successful upload. Mirrors the JSON the web client reads:
/// the `url` is what gets pasted into the composer, `mime` is derived from the magic bytes
/// (trust it over any client guess), and `thumbnailUrl` is present only when the server
/// hosted the thumbnail remotely.
public struct UploadResponse: Sendable, Equatable {
    public let id: Int
    public let url: String
    public let mime: String?
    public let canDelete: Bool
    public let thumbnailUrl: String?
}

/// Everything that can go wrong turning a picked file into a pasted URL. Each case carries a
/// user-facing sentence so the presenter never has to interpret an error code.
public enum UploadError: Error, Sendable, Equatable {
    /// No live session — the token was dropped between picking and uploading.
    case notSignedIn
    /// The session token was rejected (401). The client also bounces to sign-in.
    case unauthorized
    /// The server refused the file for exceeding its size cap (413) — the video was already
    /// compressed as far as we go, or an image somehow arrived over the ceiling.
    case tooLarge
    /// Compression ran but couldn't get the video under the cap (a very long/high-motion 4K
    /// clip). Distinct from `.tooLarge` because it happened on-device, before any request.
    case cannotCompressEnough
    /// The transcode itself failed (unsupported codec, corrupt source, cancelled export).
    case compressionFailed(String)
    /// A non-2xx response carrying the server's own `error` string.
    case server(String)
    /// A transport-level failure (offline, TLS, timeout) — the URLError's description.
    case transport(String)

    /// The sentence shown to the user. Written to be actionable where we can be, honest
    /// where we can't.
    public var userMessage: String {
        switch self {
        case .notSignedIn:
            return "You're not signed in."
        case .unauthorized:
            return "Your session expired. Sign in again to upload."
        case .tooLarge:
            return "The server rejected this file for being too large."
        case .cannotCompressEnough:
            return "This video is too large to upload, even after compression."
        case .compressionFailed(let why):
            return "Couldn't process this video: \(why)"
        case .server(let msg):
            return msg
        case .transport(let why):
            return "Upload failed: \(why)"
        }
    }
}

/// One `upload-progress` frame: the server narrating the half of an upload this device
/// cannot see (#47; server-side #545).
///
/// `URLSession`'s `didSendBodyData` measures device→server and nothing else. When it reads
/// 100% the file has merely *arrived* at the cell — and then the two slowest phases run: the
/// sharp/scrub pipeline, and the server→provider send, which on a home uplink is by far the
/// longest. Only the server knows about those, so only the server can narrate them.
public struct UploadServerProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        /// The server's pipeline (image re-encode / media scrub). A one-shot native call with
        /// no seam to count, so it never carries a percentage.
        case processing
        /// The send to the provider. Carries a percentage only when the driver can report
        /// bytes — `local` renames a temp file, and there is no wire to count.
        case sending
    }

    public let phase: Phase
    /// 0…100 for the provider send, or nil when there is no number to give.
    public let percent: Int?
    /// The resolved uploader's human label ("Catbox", "Local disk"), so the readout can name
    /// where the file is going. Nil when the server didn't say.
    public let destination: String?

    public init(phase: Phase, percent: Int?, destination: String?) {
        self.phase = phase
        self.percent = percent
        self.destination = destination
    }
}

/// The legs of an upload, folded into the one thing the readout renders.
///
/// **Tier 1 is local and unconditional; tier 2 only refines it.** The moment the device leg
/// finishes, this advances to `.processing` on its own — without waiting for any frame. That
/// alone kills the "Uploading… 100%" dead air even against an old server or a dropped socket,
/// and the server's frames then sharpen the label rather than enable it. Progress is a
/// courtesy, never a precondition: the HTTP response is still what completes the upload.
public struct UploadProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        /// device → server, the only leg `URLSession` can see.
        case uploading
        /// The server's pipeline. Indeterminate by nature.
        case processing
        /// server → provider. The long one.
        case sending
    }

    public private(set) var stage: Stage = .uploading
    /// 0…1 for the device leg. Only meaningful while `stage == .uploading`.
    public private(set) var deviceFraction: Double = 0
    /// 0…1 for the provider send, or nil when the phase can't be counted.
    public private(set) var sentFraction: Double?
    /// Sticky once the server names it: a later frame that omits the destination must not
    /// blank a label that is already on screen.
    public private(set) var destination: String?

    public init() {}

    /// A `didSendBodyData` tick. Advances to `.processing` at 100% by itself — see the type's
    /// note on tier 1 — and is otherwise **ignored once a later stage has begun**. Those
    /// callbacks hop threads to reach the main actor, so a straggler can land after the
    /// server's first frame; letting one rewind the readout to "Uploading…" would undo the
    /// very thing this exists to fix.
    public mutating func apply(deviceFraction fraction: Double) {
        guard stage == .uploading else { return }
        deviceFraction = max(0, min(1, fraction))
        if deviceFraction >= 1 { stage = .processing }
    }

    /// A server frame. Monotonic in the same direction and for the same reason: a delayed
    /// `processing` arriving after `sending` has begun would rewind a real percentage to an
    /// indeterminate label. WS ordering makes that unlikely, not impossible, and a visibly
    /// jumping readout is more expensive than the guard.
    public mutating func apply(server frame: UploadServerProgress) {
        if let destination = frame.destination, !destination.isEmpty {
            self.destination = destination
        }
        if stage == .sending && frame.phase == .processing { return }
        switch frame.phase {
        case .processing:
            stage = .processing
            sentFraction = nil
        case .sending:
            stage = .sending
            // A percentage only where one was actually reported. An assumed 0% would freeze
            // at "Sending to Local disk… 0%" for a driver that never counts a byte — the same
            // species of lie as the 100% this whole feature exists to kill.
            sentFraction = frame.percent.map { Double(max(0, min(100, $0))) / 100 }
        }
    }
}

/// Assembles a `multipart/form-data` body **to a file on disk**, streaming the source in
/// chunks so a 200 MB video is never held in memory. The whole feature turns on this: the
/// server's own upload route went to disk-backed multer for exactly this reason (a 200 MB
/// upload used to cost ~1 GB of RSS), and buffering the body here would just move that cost
/// to the phone, which has far less headroom.
enum MultipartBody {
    struct Assembled {
        let fileURL: URL
        let contentType: String
    }

    /// A filename can't carry a bare `"`/CR/LF into the `Content-Disposition` header without
    /// breaking it (or, worse, injecting a header). Strip control chars and quotes; the
    /// server re-derives the real extension from the magic bytes anyway, so this value is
    /// only ever the display name.
    static func sanitizeFilename(_ name: String) -> String {
        let cleaned = name.unicodeScalars.filter { $0 != "\"" && !CharacterSet.controlCharacters.contains($0) }
        let result = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "upload" : result
    }

    /// Field order is load-bearing: `progressToken` **before** `image`, because the server
    /// parses multipart fields in stream order and reads the token before the (huge) file
    /// body streams past — a token appended behind the file wouldn't exist yet when the
    /// route wires up progress. This mirrors the web client's `FormData` ordering.
    static func assemble(
        token: String,
        fileURL: URL,
        filename: String,
        mime: String
    ) throws -> Assembled {
        let boundary = "LurkerBoundary-\(UUID().uuidString)"
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lurker-upload-\(UUID().uuidString).multipart")

        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        defer { try? out.close() }

        func write(_ string: String) throws {
            try out.write(contentsOf: Data(string.utf8))
        }

        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"progressToken\"\r\n\r\n")
        try write("\(token)\r\n")

        try write("--\(boundary)\r\n")
        try write(
            "Content-Disposition: form-data; name=\"image\"; filename=\"\(sanitizeFilename(filename))\"\r\n"
        )
        try write("Content-Type: \(mime)\r\n\r\n")

        // Stream the source file in 1 MB chunks straight into the body file — never a full
        // `Data(contentsOf:)`, which would defeat the whole disk-backed design.
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }

        try write("\r\n--\(boundary)--\r\n")

        return Assembled(fileURL: outURL, contentType: "multipart/form-data; boundary=\(boundary)")
    }
}

/// Per-task delegate that turns `URLSession`'s byte-sent callbacks into a 0…1 fraction. This
/// is the device→server leg only; the slower server→provider leg is narrated over the WS as
/// `UploadServerProgress`, and `UploadProgress` folds the two together.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    /// Last whole-percent forwarded. URLSession fires `didSendBodyData` far more often than a
    /// bar can repaint, so we coalesce to ~101 updates over the whole upload instead of one
    /// per chunk (which each spawn a main-actor hop downstream). The callbacks arrive on the
    /// session's serial delegate queue, so this unsynchronized state is race-free.
    private var lastPercent = -1

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let percent = Int(Double(totalBytesSent) / Double(totalBytesExpectedToSend) * 100)
        guard percent != lastPercent else { return }
        lastPercent = percent
        onProgress(Double(percent) / 100)
    }
}
