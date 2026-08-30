// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

extension UIViewController {

    /// The recent-highlights list. App-scoped, not buffer-scoped — highlights span every
    /// network — so both screens that can reach it get the same one from here rather than the
    /// chat screen owning it and the buffer list growing a second copy.
    func showHighlights(viewModel: ChatViewModel) {
        showHistoryFeed(HighlightsViewController(viewModel: viewModel), viewModel: viewModel)
    }

    /// The bookmarks list. App-scoped for the same reason highlights is, and reached the same
    /// way from the same places.
    func showBookmarks(viewModel: ChatViewModel) {
        showHistoryFeed(BookmarksViewController(viewModel: viewModel), viewModel: viewModel)
    }

    /// Message search, presented — the entry point for screens that don't have the buffer
    /// list's permanent bottom search field under them.
    ///
    /// `seed` prefills the query field, which is how "search this conversation" works: there
    /// is no separate scoped mode, just an `in:`/`on:` prefix in the same field, which the
    /// user can then edit or delete. Same trick the web client uses, and the reason the filter
    /// grammar is a *grammar* rather than a row of chips.
    func showSearch(viewModel: ChatViewModel, seed: String = "") {
        showHistoryFeed(
            MessageSearchViewController(viewModel: viewModel, presentation: .standalone, seed: seed),
            viewModel: viewModel
        )
    }

    /// The uploads browser (#138). App-scoped like Highlights and Bookmarks — what you have
    /// uploaded spans every network — and reached from the same menus.
    ///
    /// `onInsert` is what makes this screen different from the other three: given one, a file can
    /// go straight into the composer you came from. The buffer list passes nil, because there is
    /// no composer behind it and an insert would land nowhere.
    func showUploads(viewModel: ChatViewModel, onInsert: ((String) -> Void)? = nil) {
        guard presentedViewController == nil, navigationController?.presentedViewController == nil
        else { return }
        let uploads = UploadsViewController(viewModel: viewModel)
        uploads.onInsert = onInsert
        let sheet = UINavigationController(rootViewController: uploads)
        sheet.navigationBar.prefersLargeTitles = true
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        // Presented from the navigation controller for the same reason the feeds are: this is a
        // full-height reading surface, and a presenter torn down underneath it would take it down.
        navigationController?.present(sheet, animated: true)
    }

    /// Say that the row points into a buffer that isn't open, instead of navigating into a
    /// screen that would immediately throw the user back out.
    ///
    /// Presented from the feed rather than after dismissing it: the sheet is where the user
    /// is, the answer belongs there, and staying put lets them pick a different row. There is
    /// no offer to reopen the buffer — reopening is a real decision (rejoining a channel, or
    /// starting a DM), not a side effect of tapping something to read.
    fileprivate func reportClosedBuffer(_ item: HighlightItem, viewModel: ChatViewModel) {
        let name = viewModel.state.buffer(for: item.bufferKey)
            .displayName(networkName: item.networkName
                ?? item.networkId.flatMap { viewModel.state.networks[$0]?.name })
        let alert = UIAlertController(
            title: "Buffer Closed",
            message: "\(name) isn't open, so this message can't be shown in context.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Present a cross-buffer feed and wire its jump.
    ///
    /// A full-height sheet: these are reading surfaces, not glances. Presented from the
    /// *navigation controller* rather than from `self`, because picking a row replaces
    /// whatever is on the stack, and a presenter deallocated mid-swap takes its sheet down
    /// with it. Tapping a row lands on the line the same way `/msg` and the buffer list
    /// navigate.
    private func showHistoryFeed(_ feed: HistoryFeedViewController, viewModel: ChatViewModel) {
        guard presentedViewController == nil, navigationController?.presentedViewController == nil else { return }
        let nav = navigationController
        wireJump(feed, viewModel: viewModel, nav: nav) { [weak nav] in nav?.dismiss(animated: true) }
        let sheet = UINavigationController(rootViewController: feed)
        sheet.navigationBar.prefersLargeTitles = true
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        nav?.present(sheet, animated: true)
    }
}

/// Point a cross-buffer feed's row tap at the conversation it came from.
///
/// Shared by every feed that lists lines from elsewhere — Highlights, Bookmarks, and search —
/// because "go to this message" has to mean exactly one thing however you got to the row.
/// `close` is what differs and all that differs: a presented sheet dismisses, while the buffer
/// list's search results are dismissed by deactivating the search field that put them there.
private func wireJump(
    _ feed: HistoryFeedViewController,
    viewModel: ChatViewModel,
    nav: UINavigationController?,
    close: @escaping () -> Void
) {
    feed.onSelect = { [weak nav, weak feed] item in
        let state = viewModel.state
        // A row can outlive the buffer it points into: bookmarks and highlights are kept
        // by message id, and closing a buffer doesn't touch them. Jumping anyway is a dead
        // end — `ChatViewController.handleBufferDisappeared` finds no row for the key and
        // pops back to the list, so the sheet closes, a chat screen flashes, and you land
        // somewhere you didn't ask for with nothing said about why.
        //
        // Tested with the same condition that screen uses, so the two can't disagree about
        // what "gone" means: a settled roster is the server having listed everything it
        // has (#635). While it's still arriving, absence proves nothing — navigate, and let
        // the chat screen wait for the answer as it does for a notification tap.
        //
        // Search reaches this more often than the other two, and it isn't an edge case there:
        // the server's FTS index covers every message the account has ever received, including
        // channels long since parted, so searching for something said in a closed buffer is a
        // perfectly ordinary thing to do rather than a stale row.
        if state.rosterSettled, state.buffers[item.bufferKey.id] == nil {
            feed?.reportClosedBuffer(item, viewModel: viewModel)
            return
        }
        // Jump to the line (#42) — even when it's the buffer already on screen, since the
        // point is to move to that message. The new screen fetches an `around` slice
        // centered on it.
        nav?.showBuffer(
            state.buffer(for: item.bufferKey), viewModel: viewModel,
            jumpTo: item.message.id, animated: false
        )
        close()
    }
}

extension UINavigationController {

    /// Open a buffer, with the buffer list behind it.
    ///
    /// Five things navigate to a buffer — picking one from the list, `/msg`, a highlight tap,
    /// a notification tap, and joining a channel — and every one of them means the same
    /// thing: *this* conversation, on top of the list. So they all come through here, and
    /// back always goes to the same place no matter how you arrived.
    ///
    /// The stack is **set**, not pushed. Pushing would stack chat screens on chat screens
    /// (`/msg` from a channel, a notification tapped while reading something else), each
    /// holding a buffer's worth of messages and a live subscription, and back would walk you
    /// through your own history one conversation at a time. Exactly one chat screen exists,
    /// and the list is under it.
    ///
    /// The existing list is reused when there is one, so its scroll position and Recent
    /// ordering survive being navigated over.
    func showBuffer(
        _ buffer: Buffer,
        viewModel: ChatViewModel,
        jumpTo messageId: Int? = nil,
        animated: Bool
    ) {
        // Already reading this one, and nothing to jump to? Leave it alone. Rebuilding the
        // screen re-latches the unread divider, re-requests history, and throws away the
        // scroll position to arrive exactly where we already are — which is what tapping a
        // notification for the conversation you're looking at (a friend-online push carries
        // no messageId) would otherwise cost. A jump is a real move and still rebuilds.
        if messageId == nil,
           viewControllers.first is BufferListViewController,
           let top = viewControllers.last as? ChatViewController,
           top.buffer.key.id == buffer.key.id {
            return
        }
        let list = (viewControllers.first as? BufferListViewController) ?? makeBufferList(viewModel: viewModel)
        let chat = ChatViewController(viewModel: viewModel, buffer: buffer, jumpTo: messageId)
        setViewControllers([list, chat], animated: animated)
    }

    /// The list on its own — where the app lands when there's nothing to restore into.
    func showBufferList(viewModel: ChatViewModel, animated: Bool) {
        let list = (viewControllers.first as? BufferListViewController) ?? makeBufferList(viewModel: viewModel)
        setViewControllers([list], animated: animated)
    }

    private func makeBufferList(viewModel: ChatViewModel) -> BufferListViewController {
        let list = BufferListViewController(viewModel: viewModel)
        // Wired once, here, rather than at each construction site — the list reports a pick
        // and knows nothing about navigation, and this is the only thing that ever answers.
        list.onSelect = { [weak self] buffer in
            self?.showBuffer(buffer, viewModel: viewModel, animated: true)
        }
        // The list's search results are a cross-buffer feed like any other, so their row taps
        // mean what Highlights' and Bookmarks' do. Wired here, alongside `onSelect`, because
        // this is the one place that knows both the feed and the navigation stack — and
        // because a search result and a buffer row are the same gesture arriving at the same
        // conversation by different routes.
        wireJump(list.searchResults, viewModel: viewModel, nav: self) { [weak list] in
            list?.dismissSearch()
        }
        return list
    }
}
