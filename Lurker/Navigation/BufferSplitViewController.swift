// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The iPad root: the buffer list and the conversation, side by side.
///
/// iPad only — the phone keeps a plain `PilledNavigationController` root, untouched by any of
/// this — because a split view expands at *any* regular width, including a Pro Max in
/// landscape.
///
/// Both columns are `PilledNavigationController`s, which is what brings the status pill along
/// for free: `navigationPill` resolves through `navigationController`, so each column's screens
/// find their own column's pill, and the two already do the two jobs a split needs. The list's
/// reads "Lurker" and follows the socket — on the phone that vanishes the moment you open a
/// buffer, here the column is always up, so it becomes a permanent connection indicator.
///
/// The secondary column is never empty: nothing selected means the system buffer. The server
/// log is real content and always present, where a "No Conversation Selected" placeholder
/// would be a new screen whose whole job is to be dead space.
final class BufferSplitViewController: UISplitViewController {

    private let viewModel: ChatViewModel

    /// The buffer showing in the secondary column, so the list can mark its row and a collapse
    /// can decide which column it collapses *to*.
    ///
    /// Nil until something is picked — distinct from "the column is showing the system buffer",
    /// since you can also open that deliberately, and then collapsing should leave you in it.
    private(set) var selection: BufferKey?

    private let listNav = PilledNavigationController()
    private let chatNav = PilledNavigationController()

    private var list: BufferListViewController? {
        listNav.viewControllers.first as? BufferListViewController
    }

    /// The column the buffer list lives in — what a caller holding "the navigation controller"
    /// means on iPad. `showBuffer` on it forwards back here, so nothing outside needs to know
    /// which of the two columns it is holding.
    var primaryNavigation: UINavigationController { listNav }

    /// Drop every sheet in either column.
    ///
    /// A sheet is attached to the controller that presented it, and `dismiss` walks *up* from
    /// there — so asking the split to dismiss never reaches one the conversation column put up.
    /// Both columns have to be asked.
    func dismissPresented() {
        for nav in [listNav, chatNav] where nav.presentedViewController != nil {
            nav.dismiss(animated: false)
        }
        if presentedViewController != nil { dismiss(animated: false) }
    }

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(style: .doubleColumn)
        delegate = self

        // Tiled rather than overlaid: this is a two-pane reading app, and an overlay that
        // dims the conversation to show the list would make switching buffers modal.
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        // No hide-the-sidebar button and no swipe: the list stays up, as it does in Messages.
        // The bar also can't afford one — a ~320pt column already carrying the status pill, and
        // UIKit answers an overfull bar by dropping trailing items rather than overflowing
        // them. With the display-mode button present, the join "+" was measured going missing.
        presentsWithGesture = false
        displayModeButtonVisibility = .never

        for nav in [listNav, chatNav] {
            nav.navigationBar.prefersLargeTitles = true
        }
        // The stack's own factory, which wires the list's `onSelect` and its search results'
        // jump to `showBuffer` — the funnel that forwards back here once these navs are
        // columns. So the list knows nothing about splits.
        listNav.showBufferList(viewModel: viewModel, animated: false)
        chatNav.setViewControllers(
            [ChatViewController(viewModel: viewModel, buffer: .system)], animated: false
        )
        setViewController(listNav, for: .primary)
        setViewController(chatNav, for: .secondary)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Keep the list's marking in step with the layout. Here rather than in the collapse or
    /// expand callbacks, which run *during* the transition where `isCollapsed` still describes
    /// the arrangement being left. The setter no-ops on an unchanged value.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        list?.marksOpenBuffer = !isCollapsed
    }

    // MARK: - Navigation

    /// Open a buffer in the conversation column.
    ///
    /// The same five things reach this that reach `UINavigationController.showBuffer` — a list
    /// tap, `/msg`, a highlight, a notification, a join — since they all go through that funnel
    /// and it forwards here. Collapsed, the columns are one merged stack and `show(.secondary)`
    /// pushes onto it, which is the phone's list-then-chat arrangement.
    func showBuffer(_ buffer: Buffer, jumpTo messageId: Int? = nil, animated: Bool) {
        // Already reading it, with nothing to jump to — same early-out the stack version makes,
        // and for the same reason: rebuilding re-latches the unread divider, re-requests
        // history, and throws away the scroll position to arrive where we already are.
        // By `id`, which lower-cases the target: the same conversation reaches this as
        // `#Lurker` from one route and `#lurker` from another, and an exact key match would
        // miss that and rebuild the screen.
        if messageId == nil, selection?.id == buffer.key.id,
           chatNav.viewControllers.last is ChatViewController {
            show(.secondary)
            return
        }
        selection = buffer.key
        let chat = ChatViewController(viewModel: viewModel, buffer: buffer, jumpTo: messageId)
        // Set, never pushed. One conversation exists at a time — `/msg` from a channel or a
        // notification tapped mid-read must not leave a stack of live subscriptions behind a
        // back button that walks you through your own history.
        chatNav.setViewControllers([chat], animated: false)
        show(.secondary)
        list?.markSelection(buffer.key)
    }

    /// The conversation on screen, whichever column holds it. Never nil once signed in, since
    /// the column rests on the system buffer — which is the right answer: that screen has a
    /// composer, and is what a finished upload should insert into.
    var currentChat: ChatViewController? {
        let nav = isCollapsed ? listNav : chatNav
        return nav.topViewController as? ChatViewController
    }

    /// Forget which conversation is open, and drop the column back to the server log. For the
    /// exit this class doesn't own: a Back tap in a collapsed split. `showBufferList` is the
    /// expanded equivalent, plus showing the primary column — already done by the time a
    /// collapsed pop reaches here.
    func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        chatNav.setViewControllers(
            [ChatViewController(viewModel: viewModel, buffer: .system)], animated: false
        )
        list?.markSelection(nil)
    }

    /// Nothing selected: the list, with the server log beside it. Where sign-in lands with no
    /// remembered buffer, and where a buffer that disappears under its reader goes — the
    /// split's answer to `popToRootViewController`, which has nothing to pop to here.
    func showBufferList(animated: Bool) {
        selection = nil
        chatNav.setViewControllers(
            [ChatViewController(viewModel: viewModel, buffer: .system)], animated: false
        )
        show(.primary)
        list?.markSelection(nil)
    }
}

// MARK: - Collapsing

extension BufferSplitViewController: UISplitViewControllerDelegate {

    /// Which column survives being squeezed into one: the conversation you were reading, or
    /// the list rather than a server log nobody asked for. `selection` is the question and not
    /// "is the secondary column showing something", which is always true.
    func splitViewController(
        _ svc: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposed: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        selection == nil ? .primary : .secondary
    }

    func splitViewController(
        _ svc: UISplitViewController,
        displayModeForExpandingToProposedDisplayMode proposed: UISplitViewController.DisplayMode
    ) -> UISplitViewController.DisplayMode {
        .oneBesideSecondary
    }
}
