// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

extension UIViewController {

    /// The recent-highlights list. App-scoped, not buffer-scoped — highlights span every
    /// network — so both screens that can reach it get the same one from here rather than the
    /// chat screen owning it and the buffer list growing a second copy.
    ///
    /// A full-height sheet: it's a reading surface, not a glance. Presented from the
    /// *navigation controller* rather than from `self`, because picking a highlight replaces
    /// whatever is on the stack, and a presenter deallocated mid-swap takes its sheet down
    /// with it. Tapping a highlight lands on the matched line the same way `/msg` and the
    /// buffer list navigate.
    func showHighlights(viewModel: ChatViewModel) {
        guard presentedViewController == nil, navigationController?.presentedViewController == nil else { return }
        let nav = navigationController
        let highlights = HighlightsViewController(viewModel: viewModel)
        highlights.onSelect = { [weak nav] item in
            // Jump to the matched line (#42) — even when it's the buffer already on screen,
            // since the point is to move to that message. The buffer may not be in state (a
            // channel since closed, or one whose row never materialized), which is what
            // `buffer(for:)` synthesizes for; the new screen fetches an `around` slice
            // centered on the match and scrolls to it.
            nav?.showBuffer(
                viewModel.state.buffer(for: item.bufferKey), viewModel: viewModel,
                jumpTo: item.message.id, animated: false
            )
            nav?.dismiss(animated: true)
        }
        let sheet = UINavigationController(rootViewController: highlights)
        sheet.navigationBar.prefersLargeTitles = true
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        nav?.present(sheet, animated: true)
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
        return list
    }
}
