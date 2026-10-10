// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Runs a `StatusToastQueue` for one surface — the chat screen's status row, or the capsule over
/// the buffer list: holds each toast for its time, then brings on the next. The surface draws;
/// this decides what it draws and when.
@MainActor
final class StatusToastPresenter {
    private var queue = StatusToastQueue()
    private var timer: Timer?

    /// The toast showing now.
    var active: StatusToast? { queue.active }

    /// Whether the surface is free for the next toast. False holds the queue until `presentNext`
    /// is called again — the completion chips own the status row while they're up.
    var isReady: () -> Bool = { true }
    /// Whether the surface can be seen at all, asked before each toast. False drops whatever
    /// waits: one shown under a sheet, or after the screen has gone, would expire unseen while
    /// its announcement spoke over somewhere else.
    var isVisible: () -> Bool = { true }
    /// A toast about to go up. False means it went somewhere else instead — a notice too long for
    /// the one-line row floats where it can wrap — and the next one is tried.
    var shouldPresent: (StatusToast) -> Bool = { _ in true }
    /// The toast showing changed, or went: draw what's current.
    var onChange: () -> Void = {}
    /// A toast went up (`isNew`), or the one up was updated in place.
    var onShow: (_ toast: StatusToast, _ isNew: Bool) -> Void = { _, _ in }

    func show(_ toast: StatusToast) {
        switch queue.offer(toast) {
        case .updatedActive:
            onChange()
            onShow(toast, false)
        case .updatedWaiting:
            break
        case .preemptedActive:
            stopTimer()
            onChange()
            presentNext()
        case .queued:
            presentNext()
        }
    }

    /// Bring on the next toast, if the surface is free and one waits.
    func presentNext() {
        guard isReady(), active == nil, !queue.waiting.isEmpty else { return }
        guard isVisible() else {
            // Passing news, gone stale while nobody could see it; the counts still have the rest.
            queue.dropWaiting()
            return
        }
        guard let (next, hold) = queue.presentNext() else { return }
        guard shouldPresent(next) else {
            queue.endActive()
            return presentNext()
        }
        let timer = Timer(timeInterval: hold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.queue.endActive()
                self.onChange()
                self.presentNext()
            }
        }
        // `.common`, so it runs out while the list underneath is being scrolled.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        onChange()
        onShow(next, true)
    }

    /// The toast showing was tapped: take it down and return it. The caller acts on it, then
    /// calls `presentNext` — after, so a tap that leaves the screen doesn't start the next toast
    /// on the way out.
    func takeActive() -> StatusToast? {
        guard let toast = active else { return nil }
        stopTimer()
        queue.endActive()
        onChange()
        return toast
    }

    /// Put the toast showing back at the front of the queue, to be shown in full once the
    /// surface is free again.
    func requeueActive() {
        guard active != nil else { return }
        stopTimer()
        queue.requeueActive()
        onChange()
    }

    /// Take everything down: the surface is going away.
    func clear() {
        stopTimer()
        queue.endActive()
        queue.dropWaiting()
        onChange()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension UIViewController {
    /// In a window with nothing presented over it — where a toast on this screen can be seen. A
    /// sheet (a conversation's info, Settings, the color editor) covers it.
    ///
    /// ⚠ Side by side, a sheet from EITHER column covers it. Each column presents its own sheets,
    /// so Settings opened from the sidebar is the list's, and none of the three checks below would
    /// see it from the conversation: the toast would run out behind the dimmed sheet, sound and
    /// all. `topPresented` asks both columns.
    var isUncovered: Bool {
        view.window != nil && presentedViewController == nil
            && navigationController?.presentedViewController == nil
            && splitViewController?.presentedViewController == nil
            && (splitViewController as? BufferSplitViewController)?.topPresented == nil
    }
}

extension StatusToast {
    /// Who and what — "bob: are you around?" — the way the line reads in the buffer; where it
    /// happened is the tap's job. A kick has no speaker worth naming, so it says where. A notice
    /// is in the error color behind a glyph, so "Not connected" can't be read as someone's line.
    func attributedText(font: UIFont) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let muted: [NSAttributedString.Key: Any] = [.foregroundColor: Palette.fgMuted, .font: font]
        switch self {
        case .notice(let message):
            let glyph = UIImage(
                systemName: "exclamationmark.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small)
            )?.withTintColor(Palette.bad, renderingMode: .alwaysOriginal)
            if let glyph {
                text.append(NSAttributedString(attachment: NSTextAttachment(image: glyph)))
                text.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            text.append(NSAttributedString(string: message, attributes: [.foregroundColor: Palette.bad, .font: font]))
        case .notification(let notification):
            if notification.kind == .kicked {
                text.append(NSAttributedString(string: "Kicked from " + notification.key.target, attributes: muted))
            } else {
                let nick = notification.nick ?? "?"
                text.append(NSAttributedString(string: nick, attributes: [
                    .foregroundColor: MessageRenderer.hashedColor(nick), .font: font,
                ]))
                if notification.kind == .friendOnline {
                    text.append(NSAttributedString(string: " came online", attributes: muted))
                }
            }
            if !notification.text.isEmpty {
                text.append(NSAttributedString(
                    string: ": " + notification.text, attributes: [.foregroundColor: Palette.fg, .font: font]
                ))
            }
        }
        return text
    }
}
