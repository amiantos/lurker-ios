// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine

/// Keeps the app-icon badge equal to `ChatState.totalHighlights` (#490).
///
/// The icon has two writers: this, and iOS itself painting a push's `aps.badge`. A push
/// carries the server's count at SEND time and can land late — after the socket has
/// already delivered the read-state that emptied it — so it can paint a number our derived
/// count already disagrees with. Publishing only the count's *transitions* can never
/// repair that (#134): the count didn't move, so the write that would correct the icon is
/// exactly the one a dedupe swallows, and the icon reads a stale number until something
/// happens to move the real one.
///
/// So the current count is also re-asserted, dedupe or no, at moments a push may have
/// painted over it:
///
///  - when a snapshot burst completes. Every reconnect produces one — including the one
///    `enterForeground` makes after a long background, the window most pushes land in —
///    and its terminal frame is the moment the count is known fresh rather than a
///    pre-background leftover.
///  - when the app asks (`reassert`) — the scene delegate does so on activation, which is
///    when the user has just been looking at the icon.
///
/// Only the kit's `write` closure ever touches the OS: same shape as reachability and
/// push, the app does the `UserNotifications` call and this decides the number.
@MainActor
public final class AppBadge {
    private let write: (Int) -> Void
    private var cancellable: AnyCancellable?

    public init(write: @escaping (Int) -> Void) {
        self.write = write
    }

    /// Follow `states` for the app's lifetime. `statePublisher` replays the current state
    /// on subscribe, so this writes once immediately.
    public func follow(_ states: AnyPublisher<ChatState, Never>) {
        cancellable = states
            // Keyed on burst completion as well as the count, so a burst's terminal frame
            // is a write even when the count it confirms hasn't moved. The burst's start
            // flips `rosterSettled` back off and writes too; that one is incidental and
            // harmless — it carries the count already on the icon.
            .map { (count: $0.totalHighlights, settled: $0.rosterSettled) }
            .removeDuplicates { $0 == $1 }
            .sink { [write] in write($0.count) }
    }

    /// Write the current count regardless of whether it changed.
    public func reassert(_ state: ChatState) {
        write(state.totalHighlights)
    }
}
