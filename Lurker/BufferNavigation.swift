// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

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
