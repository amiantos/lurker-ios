// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// How much join/part/quit/nick/host-change/mode noise reaches the message list — a port of
/// the web's `shared/eventFilter.ts` (#666), reading the same server-side settings so the
/// phone and the browser can't disagree about the rules.
///
/// This replaced two independent switches that answered the same question between them
/// (`chat.consolidate_joins` and `chat.smart_filter`), and added the rung neither could
/// express: hide all of it. That rung is why the tier exists — a phone screen holds a
/// fraction of the lines a desktop one does, and presence churn costs proportionally more.
public enum EventMode: String, CaseIterable, Sendable {
    /// Every event renders, folded into summary lines when `chat.consolidate_joins` is on.
    case all
    /// Events render only for nicks who have recently spoken.
    ///
    /// **Not implemented on iOS yet — this app renders it as `.all`.** The filter needs each
    /// nick's last-spoke time, which the server ships as a `speakers` list on the `backlog`
    /// and `history` frames and this client currently drops on the floor. Carrying it means
    /// widening both frame cases, holding it in `ChatState`, and threading it into
    /// `MessageRows.build`; until that lands, offering the rung silently would mean a phone
    /// showing every event while its setting claims otherwise. `EventFilter.isSelectable`
    /// keeps it out of the picker and the settings screen labels it as web-only.
    case smart
    /// No event rows at all. Conversation only.
    case none
}

/// The tier, the row types it hides, and the page unit that matches.
public enum EventFilter {

    /// The settings key the phone reads.
    ///
    /// Unconditionally the mobile one: the tier is split by device class (the web switches on
    /// viewport width) and a phone is never the desktop case. Only the *tier* is split —
    /// the modifiers below it are shared, because at `.none` they're moot anyway and nobody
    /// wants a different consolidation cap on their phone than at their desk.
    public static let modeKey = "chat.events.mobile"

    /// The tier in force, defaulting to the registry's own default so behavior doesn't shift
    /// under the reader when settings bootstrap lands a moment after launch.
    public static func mode(_ settings: Settings) -> EventMode {
        EventMode(rawValue: settings.string(modeKey, default: EventMode.all.rawValue)) ?? .all
    }

    /// The row types `.none` hides: everything consolidation folds, plus `mode`.
    ///
    /// `mode` is excluded from `Consolidation.consolidatableTypes` on purpose — being opped
    /// or banned is worth its own line, and it has no per-nick net effect to summarize. But a
    /// reader who asked for *no* event noise means op/voice/ban churn too, so the strictest
    /// rung takes it as well.
    ///
    /// Deliberately absent, because they are things that happened rather than churn: `kick`
    /// (someone was removed, and by whom), `topic`, `invite`, `error`. Hiding those would make
    /// the buffer lie about what happened rather than merely be quieter.
    public static let noiseTypes: Set<EventType> = Consolidation.consolidatableTypes.union([.mode])

    /// Whether a message is event noise, i.e. hidden entirely at `.none`.
    public static func isNoise(_ type: EventType) -> Bool { noiseTypes.contains(type) }

    /// Whether this app can actually deliver a rung, and so whether it should offer it.
    ///
    /// `.smart` is the one that can't (see `EventMode.smart`). It stays *readable* — the key
    /// is shared with the web, which does implement it, so a value set at a desk has to remain
    /// visible on the phone rather than silently reading back as something else — but the
    /// picker won't let you newly choose a rung this client would then ignore.
    public static func isSelectable(_ mode: EventMode) -> Bool { mode != .smart }

    /// How a stored tier actually renders here. `.smart` degrades to `.all`, which is what
    /// this client does with it — stated once, so no caller has to infer it from the absence
    /// of a branch.
    public static func rendered(_ mode: EventMode) -> EventMode { mode == .smart ? .all : mode }
}
