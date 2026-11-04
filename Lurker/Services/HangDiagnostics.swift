// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import MetricKit
import UIKit

/// What the app keeps about its own freezes, so the next one explains itself.
///
/// Since the flipped message list (build 21) the app has frozen on the main thread a handful
/// of times a week — unlocking the phone, closing a photo, opening the camera — until the
/// watchdog killed it. The reports Apple writes for those are a single snapshot of the stuck
/// thread, deep in UIKit's layout, with nothing of ours above the trigger; three of them in a
/// row said the same and named nothing. Nobody has reproduced it on a cable. So the app
/// carries its own instruments, on every build, and hands the results over through the share
/// sheet in Settings like the scroll trace (`ScrollTrace`).
///
/// Three probes, one per way a layout can take forever:
/// - UIKit's layout feedback loop detector, switched on through the default UIKit reads it from.
///   A view laid out more than the threshold in a single run loop turn stops the app and names
///   the views involved. That is what a feedback loop looks like, and a stop with names beats a
///   thirty-second freeze and a snapshot without them.
/// - MetricKit's hang and crash diagnostics, which arrive on the next launch with a sampled call
///   stack tree of the stuck thread — the stack the watchdog report lacks. Saved as JSON.
/// - A view census, once a minute: the view count under every window and the views with the
///   most children. A leak of subviews makes every size change walk them all, and grows with the
///   session, which is the other shape that fits "a transition, after hours of use".
///
/// Costs nothing it can be seen to cost: the detector is a counter UIKit keeps anyway, MetricKit
/// delivers off-line, and the census walks a few hundred views a minute.
final class HangDiagnostics: NSObject {
    static let shared = HangDiagnostics()

    /// UIKit reads this default itself; the launch argument of the same name is just a way of
    /// setting it. Persisted rather than registered, because UIKit reads it at its own
    /// convenience and a value that only exists once this runs could be read too late — the
    /// persisted one is there from the next process's first instruction. ⚠ It outlives this
    /// code: a build that retires the probe has to `removeObject(forKey:)`, or every install
    /// keeps stopping at the threshold.
    private static let feedbackLoopKey = "UIViewLayoutFeedbackLoopDebuggingThreshold"
    private static let feedbackLoopThreshold = 100

    private static let censusInterval: TimeInterval = 60
    /// Lines kept in the census file: a day at one a minute, so the session a freeze grows
    /// over is still there from its start. Lines are short; this is a couple hundred KB at most.
    private static let censusLines = 1440
    private static let keptDiagnostics = 30
    /// Lines kept of the conversation's layout-loop log (`note`).
    private static let noteLines = 400

    /// Where the files live. Application Support, not Documents, so nothing is offered to the
    /// Files app; the share sheet in Settings is the way out, as for the scroll trace.
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Diagnostics", isDirectory: true)
    }()

    private var censusTimer: Timer?

    func install() {
        UserDefaults.standard.set(Self.feedbackLoopThreshold, forKey: Self.feedbackLoopKey)
        Self.prepareDirectory()
        MXMetricManager.shared.add(self)
        let timer = Timer(timeInterval: Self.censusInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.takeCensus(reason: "tick") }
        }
        timer.tolerance = Self.censusInterval / 6
        // The default mode, not common: a tick that lands mid-drag would walk the tree and
        // rewrite a file on the frame the finger is on. Tracking runs in its own mode, so the
        // tick waits for the drag to end.
        RunLoop.main.add(timer, forMode: .default)
        censusTimer = timer
        // The last word before a watchdog in the background, which is where two of three kills
        // happened: the app froze, the user gave up and went home.
        NotificationCenter.default.addObserver(
            self, selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
    }

    @objc private func didEnterBackground() { takeCensus(reason: "background") }

    /// Diagnostics are about this device's session, not worth a backup and wrong on a restore
    /// to another device, where they'd surface as that device's.
    private static func prepareDirectory() {
        var directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    /// A line from the conversation screen's own loop counter — the geometry a layout loop is
    /// fighting over, which neither UIKit's stop nor the watchdog's report carries. Kept in
    /// `layout.txt`, so it is in the share with everything else.
    func note(_ line: String) {
        append("\(ISO8601DateFormatter().string(from: Date())) \(line)", to: "layout.txt", keeping: Self.noteLines)
    }

    /// Every file on hand, for the share sheet. Empty until something has been written.
    var files: [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - View census

    private struct Crowd {
        let path: String
        let children: Int
    }

    /// One line per census, appended to `views.txt`: the total under every window and the five
    /// views with the most direct children, each named by its class and two ancestors. No
    /// content and no identifiers, only class names and counts.
    private func takeCensus(reason: String) {
        var total = 0
        var crowds: [Crowd] = []
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows {
            walk(window, ancestors: [], total: &total, crowds: &crowds)
        }
        crowds.sort { $0.children > $1.children }
        let top = crowds.prefix(5).map { "\($0.path)=\($0.children)" }.joined(separator: " ")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(reason) windows=\(windows.count) views=\(total) top: \(top)"
        if total > 1500 { NSLog("[hang] view census: %@", line) }
        append(line, to: "views.txt", keeping: Self.censusLines)
    }

    private func walk(_ view: UIView, ancestors: [String], total: inout Int, crowds: inout [Crowd]) {
        total += 1
        let name = String(describing: type(of: view))
        let children = view.subviews.count
        if children >= 8 {
            let path = ([name] + ancestors.prefix(2)).joined(separator: "<")
            crowds.append(Crowd(path: path, children: children))
        }
        let lineage = [name] + ancestors
        for child in view.subviews {
            walk(child, ancestors: lineage, total: &total, crowds: &crowds)
        }
    }

    private func append(_ line: String, to name: String, keeping cap: Int) {
        let url = Self.directory.appendingPathComponent(name)
        var lines = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
        lines.append(line)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - MetricKit

extension HangDiagnostics: MXMetricManagerSubscriber {
    /// Hang and crash diagnostics, one JSON file each, named by when they arrived plus a nonce:
    /// deliveries can come in bursts (a launch after days away) and the names must not collide.
    /// Delivered on whatever thread MetricKit likes, which is why this touches only the file
    /// system — and atomically, so a share mid-write never picks up half a file.
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let directory = Self.directory
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let nonce = UUID().uuidString.prefix(8)
        for (index, payload) in payloads.enumerated() {
            let kinds = [
                payload.hangDiagnostics?.isEmpty == false ? "hang" : nil,
                payload.crashDiagnostics?.isEmpty == false ? "crash" : nil,
                payload.diskWriteExceptionDiagnostics?.isEmpty == false ? "disk" : nil,
                payload.cpuExceptionDiagnostics?.isEmpty == false ? "cpu" : nil,
            ].compactMap { $0 }
            guard !kinds.isEmpty else { continue }
            let name = "diagnostic-\(stamp)-\(nonce)-\(index)-\(kinds.joined(separator: "+")).json"
            try? payload.jsonRepresentation().write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        Self.prune(directory)
    }

    /// Oldest first, past the cap. Names sort by their timestamp.
    private nonisolated static func prune(_ directory: URL) {
        let urls = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.lastPathComponent.hasPrefix("diagnostic-") }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        for url in urls.dropLast(keptDiagnostics) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
