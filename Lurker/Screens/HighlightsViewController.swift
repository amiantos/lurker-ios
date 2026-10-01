// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The activity feed (#13, iOS #183): every line a highlight rule matched — a reply to one of
/// your lines counts — and everyone's reactions to your lines, newest first, across every buffer
/// at once. A read surface, not a picker — the row shows the match
/// itself (who, where, what), so you can catch up on mentions without opening each channel;
/// tapping one jumps to that conversation.
///
/// Everything about how it looks and pages is `HistoryFeedViewController`, which this shares
/// with Bookmarks; what's left here is where the pages come from and what the empty state says.
final class HighlightsViewController: HistoryFeedViewController {
    override var feedTitle: String { "Activity" }

    override func fetchPage(before cursor: FeedCursor?) async -> HighlightsPage? {
        await viewModel.fetchActivity(cursor: cursor)
    }

    override var loadingModel: StateView.Model {
        StateView.Model(title: "Loading activity…", isLoading: true)
    }

    override var emptyModel: StateView.Model {
        StateView.Model(
            symbol: "at",
            title: "No recent activity",
            subtitle: "Mentions, replies to you and reactions to your messages show up here."
        )
    }

    override var errorModel: StateView.Model {
        StateView.Model(
            symbol: "exclamationmark.triangle",
            title: "Couldn't load activity",
            subtitle: "Pull to try again."
        )
    }
}
