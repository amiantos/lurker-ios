// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The next in-app notification to show. Exploration: the composer's status row is where it
/// surfaces, and the back button's highlight count is what's left once it's gone.
///
/// Decides *whether* a notification is worth showing, the web's `shouldNotifyInApp`: not while
/// the app is in the background (push has that), and not for the buffer already on screen,
/// where the line is arriving in plain view.
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    /// Posted with the new notification under `toastKey`. The chat screen's status row takes it,
    /// or the buffer list's capsule when no conversation is on screen.
    static let didChange = Notification.Name("ToastCenter.didChange")
    static let toastKey = "toast"

    /// Every one is passed on. A burst from one source — ChanServ answering /HELP — becomes one
    /// toast, which updates in place (`StatusToastQueue`). The web drops the repeats instead,
    /// since its first toast stays up; a one-line toast has to show the latest.
    ///
    /// The sound goes with the decision, not with whichever surface shows it, and a burst gets
    /// one: the web's per-source throttle, kept here for the sound alone.
    func post(_ notification: StatusNotification, settings: Settings) {
        guard UIApplication.shared.applicationState == .active,
              ChatViewController.activeChat()?.showsBuffer(notification.key) != true
        else { return }
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: [Self.toastKey: notification])
        if let sound = notification.sound(in: settings), !soundThrottled(notification) {
            NotificationSounds.play(sound)
        }
    }

    /// When each source last made a sound: network, buffer, nick and kind, the web's key.
    private var lastSoundAt: [String: Date] = [:]
    private static let soundThrottle: TimeInterval = 3

    private func soundThrottled(_ notification: StatusNotification, now: Date = Date()) -> Bool {
        let key = "\(notification.key.id)::\(notification.nick?.lowercased() ?? "?")::\(notification.kind.rawValue)"
        if let last = lastSoundAt[key], now.timeIntervalSince(last) < Self.soundThrottle { return true }
        lastSoundAt = lastSoundAt.filter { now.timeIntervalSince($0.value) < Self.soundThrottle }
        lastSoundAt[key] = now
        return false
    }
}
