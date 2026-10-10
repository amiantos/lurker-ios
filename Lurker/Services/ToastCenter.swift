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

    /// Posted with the new notification under `toastKey`.
    static let didChange = Notification.Name("ToastCenter.didChange")
    static let toastKey = "toast"

    /// Every one is passed on. A burst from one source — ChanServ answering /HELP — becomes one
    /// toast in the status row, which updates in place (`ComposerBar.showToast`). The web drops
    /// the repeats instead, since its first toast stays up; a one-line row has to show the latest.
    func post(_ notification: StatusNotification) {
        guard UIApplication.shared.applicationState == .active,
              ChatViewController.activeChat()?.showsBuffer(notification.key) != true
        else { return }
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: [Self.toastKey: notification])
    }
}
