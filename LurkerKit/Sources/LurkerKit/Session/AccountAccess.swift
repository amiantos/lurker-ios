// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// Whether the signed-in account may use the app (ios#18).
///
/// A paused account keeps its session and its socket, but the server won't connect it to IRC or
/// take a write, so the app shows one screen instead of a client that can't do anything.
public enum AccountAccess: Equatable, Sendable {
    case active
    /// Paused by the server. `selfHosted` only when `/api/config` said so: there an admin did it and
    /// is the one to ask. On lurker.chat, or before the config answers, there's no one to name.
    case paused(selfHosted: Bool)
}
