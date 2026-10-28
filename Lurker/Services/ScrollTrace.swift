// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The message list's diagnostics trace (lurker-ios#137): what the position machine decided and
/// the geometry it decided on, kept in memory while a hidden switch is on, for a tester to hand
/// over through the share sheet.
///
/// Why it ships rather than staying `#if DEBUG`: the bugs it exists for — the banner missing,
/// the list not following — are rare and were never once caught by reading the code. Each of
/// the four fixed so far was a frame race found by a trace that happened to be running. The
/// trace has to already be running when it happens, on the device it happens on.
///
/// Off by default and costs nothing off: callers check `isEnabled` before building a line.
/// Bounded, so a long session never grows it past a few hundred kilobytes; lines carry a buffer
/// key and a timestamp, never message text.
final class ScrollTrace {
    static let shared = ScrollTrace()

    private static let enabledKey = "scrollTraceEnabled"
    private static let capacity = 4000

    private var lines: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private(set) var isEnabled: Bool = UserDefaults.standard.bool(forKey: ScrollTrace.enabledKey)

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { note("trace", "on \(Self.build)") } else { lines.removeAll() }
    }

    /// One line, stamped. `source` is the buffer's key id (never its content).
    func note(_ source: String, _ line: String) {
        guard isEnabled else { return }
        if lines.count >= Self.capacity { lines.removeFirst(lines.count - Self.capacity + 1) }
        lines.append("\(formatter.string(from: Date())) [\(source)] \(line)")
    }

    var isEmpty: Bool { lines.isEmpty }

    /// Everything held, newest last, with a header saying which build wrote it.
    func export() -> String {
        (["Lurker scroll trace — \(Self.build)", ""] + lines).joined(separator: "\n") + "\n"
    }

    private static var build: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let number = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(number))"
    }
}
