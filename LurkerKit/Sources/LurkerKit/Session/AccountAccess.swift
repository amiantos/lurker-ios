// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// Whether the signed-in account may use the app (ios#18).
///
/// A paused account keeps its session and its socket, but the server won't connect it to IRC or
/// take a write, so the app shows one screen instead of a client that can't do anything.
public enum AccountAccess: Equatable, Sendable {
    case active
    /// Paused by the server. `hosted` is a lurker.chat cell, where the control plane did it; a
    /// self-hosted instance's admin did it otherwise, and is the one to ask.
    case paused(hosted: Bool)
}
