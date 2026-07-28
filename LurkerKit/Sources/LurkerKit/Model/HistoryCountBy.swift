// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// What `limit` counts on a history request (`countBy`, WS_PROTOCOL_FIXES #10).
///
/// The server sizes a page in stored rows. We render *consolidated* rows, folding each run of
/// join/part/quit/nick/chghost into one summary line (`Consolidation.consolidatableTypes`). On
/// a channel coming back from a netsplit those are wildly different numbers: a hundred stored
/// rows can render as three visible lines, so we'd hydrate, fold it to nothing, notice the page
/// looked short, page again — and the reader would watch the buffer assemble itself.
///
/// `.renderable` asks the server to spend the budget only on rows that render as their own
/// line. The churn still arrives — consolidation needs the whole run to summarize it accurately
/// — it just no longer eats the page.
enum HistoryCountBy: String, Sendable {
    /// Every stored row counts. The protocol default, and what an older server does regardless.
    case event
    /// Only rows that render standalone count.
    case renderable

    /// The unit to *ask* for, given what we're going to *render* in.
    ///
    /// These must match. With `chat.consolidate_joins` off, every event gets its own line, so
    /// `.event` is already correct — and asking for `.renderable` there would pull the server's
    /// whole scan window (up to 2000 rows) into a page the reader then sees in full. The
    /// default mirrors the registry's, so behavior doesn't shift under the user when settings
    /// bootstrap lands a moment after launch.
    static func forRendering(_ settings: Settings) -> HistoryCountBy {
        settings.bool("chat.consolidate_joins", default: true) ? .renderable : .event
    }
}
