// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Rewrites a JSON document so `JSONSerialization` reads back the strings the server wrote.
/// Foundation's decoder differs from `JSON.parse` (and from the Android client's kotlinx) in
/// two places, and both lose user text:
///
/// - **A lone surrogate escape fails the whole document** (lurker-ios#195). `"\ud83d"` with
///   no low half is exactly what `JSON.stringify` writes when a server-side `slice` cuts an
///   emoji in half: a truncated reply-parent preview, a capped description. One such string
///   anywhere in a `backlog` frame cost the whole backlog; in a `snapshot`, the roster. The
///   escape becomes `\ufffd` — a Swift `String` can't hold a lone surrogate anyway, and U+FFFD
///   is what a browser draws for one.
/// - **One leading U+FEFF is stripped from every string**, key or value, at any depth, raw or
///   escaped (lurker-ios#196) — the decoder treats it as a byte-order mark. Text pasted from
///   Word can begin with one, and iOS then showed different text from the web. Only ONE is
///   stripped, so the repair writes a second, in the same form, for the decoder to eat.
///
/// `JSONDecoder` shares the first quirk but not the second, so it has its own entry point.
///
/// Everything else passes through untouched; a document that is malformed some other way is
/// left for the decoder to reject. Repairs are rare, so the scan only notes where they go, and
/// a document that needs none is handed over as it came.
enum JSONTextRepair {

    /// The bytes to hand `JSONSerialization` for `text`.
    static func data(for text: String) -> Data {
        var text = text
        return text.withUTF8 { bytes in
            repaired(bytes, doubling: serializationStripsBOM) ?? Data(bytes)
        }
    }

    /// `data`, repaired for `JSONSerialization` — a REST body that arrives as bytes.
    static func data(for data: Data) -> Data {
        data.withUnsafeBytes { raw in
            repaired(raw.assumingMemoryBound(to: UInt8.self), doubling: serializationStripsBOM)
        } ?? data
    }

    /// `data`, repaired for `JSONDecoder`, which keeps a leading U+FEFF but still refuses a
    /// lone surrogate.
    static func forDecoder(_ data: Data) -> Data {
        data.withUnsafeBytes { raw in
            repaired(raw.assumingMemoryBound(to: UInt8.self), doubling: .neither)
        } ?? data
    }

    /// Which forms of a leading U+FEFF the decoder strips, so which to double.
    struct BOMDoubling: Equatable {
        var raw: Bool
        var escaped: Bool
        static let neither = BOMDoubling(raw: false, escaped: false)
    }

    /// Whether this Foundation strips a leading U+FEFF, raw and escaped, each asked of the
    /// decoder rather than assumed: a Foundation that stops doing it for either form would
    /// otherwise show a doubled character in every such string.
    static let serializationStripsBOM = BOMDoubling(
        raw: stripsLeadingCharacter(of: "[\"\u{FEFF}\"]"),
        escaped: stripsLeadingCharacter(of: #"["\ufeff"]"#)
    )

    private static func stripsLeadingCharacter(of probe: String) -> Bool {
        guard let decoded = (try? JSONSerialization.jsonObject(with: Data(probe.utf8))) as? [String] else { return false }
        return decoded.first?.unicodeScalars.isEmpty == true
    }

    /// The repaired document, or nil when there was nothing to repair. A single pass that
    /// tracks only whether it is inside a string: outside one, JSON has no `"` but the ones
    /// that open strings, and inside one a `"` is always escaped.
    static func repaired(_ bytes: UnsafeBufferPointer<UInt8>, doubling: BOMDoubling) -> Data? {
        // (offset, bytes replaced, replacement). Repairs are rare, so the document is copied
        // only once at the end, and only when there is one.
        var edits: [(at: Int, length: Int, with: [UInt8])] = []
        let count = bytes.count
        var i = 0
        var inString = false

        while i < count {
            let byte = bytes[i]
            guard inString else {
                i += 1
                if byte == quote {
                    inString = true
                    if let bom = leadingBOM(bytes, at: i, doubling: doubling) {
                        edits.append((i, 0, bom))
                    }
                }
                continue
            }
            if byte == quote {
                inString = false
                i += 1
                continue
            }
            guard byte == backslash else {
                i += 1
                continue
            }
            // An escape. Anything but `\u` is two bytes; a `\u` with no four hex digits is
            // malformed, and stepping past the `\u` leaves it for the decoder to refuse.
            guard let unit = escapedUnit(bytes, at: i) else {
                i += 2
                continue
            }
            if isHighSurrogate(unit) {
                if let next = escapedUnit(bytes, at: i + 6), isLowSurrogate(next) {
                    i += 12
                    continue
                }
                edits.append((i, 6, replacementEscape))
            } else if isLowSurrogate(unit) {
                // A low half the loop reached on its own had no high half before it.
                edits.append((i, 6, replacementEscape))
            }
            i += 6
        }

        guard !edits.isEmpty else { return nil }
        var out = Data(capacity: count + edits.count * rawBOM.count)
        var copied = 0
        for edit in edits {
            out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[copied..<edit.at]))
            out.append(contentsOf: edit.with)
            copied = edit.at + edit.length
        }
        out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[copied..<count]))
        return out
    }

    // MARK: - Private

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let rawBOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let escapedBOM = Array(#"\ufeff"#.utf8)
    private static let replacementEscape = Array(#"\ufffd"#.utf8)

    /// The U+FEFF to write in front of a string starting at `i`, in the form it starts with,
    /// when the decoder strips that form; nil otherwise.
    private static func leadingBOM(
        _ bytes: UnsafeBufferPointer<UInt8>, at i: Int, doubling: BOMDoubling
    ) -> [UInt8]? {
        if doubling.raw, i + 2 < bytes.count,
           bytes[i] == rawBOM[0], bytes[i + 1] == rawBOM[1], bytes[i + 2] == rawBOM[2] {
            return rawBOM
        }
        if doubling.escaped, escapedUnit(bytes, at: i) == 0xFEFF {
            return escapedBOM
        }
        return nil
    }

    /// The UTF-16 unit of a `\uXXXX` escape starting at `i`, or nil when there isn't one.
    private static func escapedUnit(_ bytes: UnsafeBufferPointer<UInt8>, at i: Int) -> UInt16? {
        guard i + 5 < bytes.count, bytes[i] == backslash, bytes[i + 1] == UInt8(ascii: "u") else { return nil }
        var unit: UInt16 = 0
        for offset in 2...5 {
            guard let digit = hexValue(bytes[i + offset]) else { return nil }
            unit = unit << 4 | UInt16(digit)
        }
        return unit
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static func isHighSurrogate(_ unit: UInt16) -> Bool { (0xD800...0xDBFF).contains(unit) }
    private static func isLowSurrogate(_ unit: UInt16) -> Bool { (0xDC00...0xDFFF).contains(unit) }
}
