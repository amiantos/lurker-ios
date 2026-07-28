// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The recent-highlights list (#13): every line a highlight rule matched, newest first,
/// across every buffer at once. A read surface, not a picker — the row shows the match
/// itself (who, where, what), so you can catch up on mentions without opening each channel;
/// tapping one jumps to that conversation.
///
/// Everything about how it looks and pages is `HistoryFeedViewController`, which this shares
/// with Bookmarks; what's left here is where the pages come from and what the empty state says.
final class HighlightsViewController: HistoryFeedViewController {
    override var feedTitle: String { "Highlights" }

    override func fetchPage(before: Int?) async -> HighlightsPage? {
        await viewModel.fetchHighlights(before: before)
    }

    override var loadingModel: StateView.Model {
        StateView.Model(title: "Loading highlights…", isLoading: true)
    }

    override var emptyModel: StateView.Model {
        StateView.Model(
            symbol: "at",
            title: "No recent highlights",
            subtitle: "Messages that match your highlight rules show up here."
        )
    }

    override var errorModel: StateView.Model {
        StateView.Model(
            symbol: "exclamationmark.triangle",
            title: "Couldn't load highlights",
            subtitle: "Pull to try again."
        )
    }
}
