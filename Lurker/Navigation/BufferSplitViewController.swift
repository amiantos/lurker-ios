// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The iPad root: the buffer list and the conversation, side by side.
///
/// Only iPad builds this — the phone keeps a plain `PilledNavigationController` root, so its
/// navigation is untouched by anything here. That is a deliberate scoping choice rather than a
/// limitation: a split view expands at *any* regular width, which on a Pro Max in landscape
/// would silently rearrange the app for people who never asked for it.
///
/// Both columns are `PilledNavigationController`s, which is what makes the status pill come
/// along for free. `UIViewController.navigationPill` resolves through `navigationController`,
/// so each column's screens find their *own* column's pill, and the two pills turn out to
/// already be doing exactly the two jobs a split needs: the list's reads "Lurker" and follows
/// the socket, the chat's reads the buffer name and follows that buffer's network. On the
/// phone the first of those disappears the moment you open a buffer; here the primary column
/// is always on screen, so it becomes a permanent connection indicator.
///
/// The secondary column is never empty. Nothing selected means the system buffer — the server
/// log is real content, it is always present, and it is what this app landed on before the
/// buffer-first redesign gave it a list to land on instead. A "No Conversation Selected"
/// placeholder would be a new screen whose whole job is to be dead space.
final class BufferSplitViewController: UISplitViewController {

    private let viewModel: ChatViewModel

    /// The buffer showing in the secondary column, so the list can mark its row and a
    /// collapse can decide which column it is collapsing *to*.
    ///
    /// Nil until something is picked. Distinct from "the secondary column is showing the
    /// system buffer", because the system buffer is also a thing you can deliberately open —
    /// and if you did, collapsing should leave you reading it rather than throwing you back
    /// to the list.
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
        // No hide-the-sidebar button, and no swipe to hide it either: the list stays up.
        //
        // Partly because that is what a two-pane messaging app does — Messages on iPad has no
        // such control — and partly because the sidebar's bar cannot afford one. It is a
        // ~320pt column already carrying the status pill, and UIKit answers an overfull bar by
        // dropping trailing items rather than overflowing them: with UIKit's own display-mode
        // button present, the join "+" was measured going missing. Settings, status, join and
        // the views menu are all worth more than a button for a thing you can do by rotating.
        presentsWithGesture = false
        displayModeButtonVisibility = .never

        for nav in [listNav, chatNav] {
            nav.navigationBar.prefersLargeTitles = true
        }
        // Built through the stack's own factory, which wires the list's `onSelect` and its
        // search results' jump to `UINavigationController.showBuffer` — the funnel that
        // forwards back here once these navs are columns. So the list needs to know nothing
        // about splits, and there is still exactly one place that opens a buffer.
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

    /// Keep the list's marking in step with the layout.
    ///
    /// Here rather than in the collapse/expand delegate callbacks because those run *during*
    /// the transition, where `isCollapsed` still describes the arrangement being left. By
    /// layout it has settled. The setter no-ops on an unchanged value, so running this every
    /// pass costs nothing.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        list?.marksOpenBuffer = !isCollapsed
    }

    // MARK: - Navigation

    /// Open a buffer in the conversation column.
    ///
    /// The same five things reach this that reach `UINavigationController.showBuffer` — a list
    /// tap, `/msg`, a highlight, a notification, a join — because they all still go through
    /// that one funnel, which forwards here when there is a split. Collapsed (an iPad in Slide
    /// Over, or a narrow Stage Manager window) the columns are one merged stack, so the phone's
    /// list-then-chat arrangement is the right one and `show(.secondary)` puts it there.
    func showBuffer(_ buffer: Buffer, jumpTo messageId: Int? = nil, animated: Bool) {
        // Already reading it, with nothing to jump to — same early-out the stack version makes,
        // and for the same reason: rebuilding re-latches the unread divider, re-requests
        // history, and throws away the scroll position to arrive where we already are.
        if messageId == nil, selection == buffer.key,
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

    /// Nothing selected: the list, with the server log beside it.
    ///
    /// What sign-in lands on when there is no remembered buffer, and where a buffer that
    /// disappears underneath its reader goes — the split's answer to the stack's
    /// `popToRootViewController`, which has nothing to pop to here.
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

    /// Which column survives being squeezed into one.
    ///
    /// Reading a conversation and it stays on screen; nothing picked and you get the list,
    /// rather than a server log nobody asked for. `selection` is the right question and not
    /// "is the secondary column showing something", because the secondary column is never
    /// empty — it holds the system buffer as its resting state.
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
