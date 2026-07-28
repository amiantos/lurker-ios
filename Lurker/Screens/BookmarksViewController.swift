// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Bookmarks: the lines you kept, newest first, across every buffer at once. Tapping one jumps
/// back to it in its conversation; swiping removes it.
///
/// Called "Bookmarks" here and in the menus that reach it, matching the web client — while the
/// *action* on a message stays "Save Message". That split is the web's too, and it's the right
/// way round: the noun names a place you go, the verb names what you're doing to one line.
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
    override var feedTitle: String { "Bookmarks" }

    override func fetchPage(before: Int?) async -> HighlightsPage? {
        await viewModel.fetchBookmarks(before: before)
    }

    override var loadingModel: StateView.Model {
        StateView.Model(title: "Loading bookmarks…", isLoading: true)
    }

    override var emptyModel: StateView.Model {
        StateView.Model(
            symbol: "bookmark",
            title: "No bookmarks",
            // Names the action exactly as the sheet does, since that's what the reader has to
            // go and find. The noun and the verb differ on purpose — see the type doc.
            subtitle: "Press and hold a message, then Save Message, to keep it here."
        )
    }

    override var errorModel: StateView.Model {
        StateView.Model(
            symbol: "exclamationmark.triangle",
            title: "Couldn't load bookmarks",
            subtitle: "Pull to try again."
        )
    }

    /// Swipe to remove. The row goes as soon as the verb is on the wire, rather than waiting
    /// for the server's echo — which is the opposite of what the message action sheet does,
    /// deliberately.
    ///
    /// The two directions aren't symmetric in what the *server* can refuse. Saving can be
    /// (a message the account doesn't own) and the refusal is answered with silence, so a
    /// sheet that flipped its own label would be inventing a bookmark. Removing is
    /// unconditional — `removeBookmark` deletes by (user, message) and always fans out — so
    /// there's no server-side failure for the row to spring back from, and leaving it in place
    /// through a round trip would just read as a broken swipe.
    ///
    /// **Delivery is the separate question, and it's why this checks.** Nothing queues a verb
    /// behind a dead socket: offline, or a few hundred ms after resume, `setBookmark` writes
    /// nowhere and says so. Removing the row anyway would be the one genuinely dishonest
    /// outcome here — the bookmark reappears next time the list is opened, with no account of
    /// where it went.
    ///
    /// Titled "Remove" to match the sheet's "Remove Bookmark" rather than the "Save" verb: this
    /// is a row in the Bookmarks list, and the thing being removed is the bookmark.
    override func trailingSwipeActions(for item: HighlightItem) -> UISwipeActionsConfiguration? {
        let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
            guard let self else { return done(false) }
            // An explicit direction, never a toggle read from the store: every row here is
            // saved by definition, but the id set only knows lines this session has loaded,
            // so flipping against it would *save* a bookmark whose buffer was never opened.
            // The message sheet passes its direction for the same reason.
            guard viewModel.setBookmark(messageId: item.message.id, saved: false) else {
                done(false)
                reportRemoveFailed()
                return
            }
            // Close the swipe BEFORE the list changes under it. A full swipe animates the row
            // out itself (`performsFirstActionWithFullSwipe` is on by default), and reloading
            // first recycles that cell to the next bookmark — so the slide-out plays on the
            // wrong row. Settling the action first leaves the reload to redraw a settled table.
            done(true)
            removeItem(id: item.message.id)
        }
        remove.image = UIImage(systemName: "bookmark.slash")
        return UISwipeActionsConfiguration(actions: [remove])
    }

    /// The swipe couldn't be delivered, so the row stays. Said out loud rather than left as a
    /// gesture that visibly did nothing: an un-animating swipe reads as a missed touch, and
    /// the user would just try again against the same dead socket.
    private func reportRemoveFailed() {
        let alert = UIAlertController(
            title: "Not Connected",
            message: "This bookmark couldn't be removed right now. Try again once you're back online.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
