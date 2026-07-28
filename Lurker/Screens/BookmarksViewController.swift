// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Saved messages: the lines you kept, newest first, across every buffer at once. Tapping one
/// jumps back to it in its conversation; swiping unsaves it.
///
/// Everything about how it looks and pages is `HistoryFeedViewController`, which this shares with
/// Highlights — the server builds both feeds from the same query, so the row shape, the cursor
/// contract and the channel+day grouping are all identical.
///
/// **Ordered by when the line was said, not when you saved it.** The server pages on message id,
/// so bookmarking something from last spring files it under last spring rather than putting it on
/// top. That's the web's behaviour too, and it's the right one for a feed you navigate by
/// conversation — but it does mean a fresh bookmark can land below the fold.
final class BookmarksViewController: HistoryFeedViewController {
    override var feedTitle: String { "Saved" }

    override func fetchPage(before: Int?) async -> HighlightsPage? {
        await viewModel.fetchBookmarks(before: before)
    }

    override var loadingModel: StateView.Model {
        StateView.Model(title: "Loading saved messages…", isLoading: true)
    }

    override var emptyModel: StateView.Model {
        StateView.Model(
            symbol: "bookmark",
            title: "No saved messages",
            subtitle: "Press and hold a message, then Save Message, to keep it here."
        )
    }

    override var errorModel: StateView.Model {
        StateView.Model(
            symbol: "exclamationmark.triangle",
            title: "Couldn't load saved messages",
            subtitle: "Pull to try again."
        )
    }

    /// Swipe to unsave. The row goes immediately rather than waiting for the server's echo —
    /// which is the opposite of what the message action sheet does, deliberately.
    ///
    /// The two directions aren't symmetric. *Saving* can be refused (a message the account
    /// doesn't own) and the server answers that refusal with silence, so a sheet that flipped
    /// its own label would be inventing a bookmark. *Unsaving* is unconditional — `removeBookmark`
    /// deletes by (user, message) and always fans out — so there is no failure for the row to
    /// spring back from, and leaving it sitting there until a round trip completes would just
    /// read as a broken swipe.
    override func trailingSwipeActions(
        for item: HighlightItem,
        at indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let remove = UIContextualAction(style: .destructive, title: "Unsave") { [weak self] _, _, done in
            guard let self else { return done(false) }
            // `setBookmark(saved: false)`, not `toggleBookmark`: every row here is saved by
            // definition, but the id set only knows lines this session has loaded, so toggling
            // against it would *save* a bookmark whose buffer was never opened.
            viewModel.setBookmark(messageId: item.message.id, saved: false)
            removeItem(at: indexPath)
            done(true)
        }
        remove.image = UIImage(systemName: "bookmark.slash")
        return UISwipeActionsConfiguration(actions: [remove])
    }
}
