// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The app's root on every device: the buffer list and the conversation, side by side where
/// there's room, collapsed into the phone's list-then-chat stack where there isn't.
///
/// Two columns only at regular × regular — an iPad, or an iPhone Duo opened to its inner
/// display. A split view on its own expands at *any* regular width, which would rearrange the
/// app for a Pro Max turned to landscape; `applyColumnRule` holds that collapsed. Collapsed is
/// not a lesser mode: it's what every other iPhone runs in all the time, and what an iPad in
/// Slide Over or a narrow Stage Manager window drops into.
///
/// Side by side, the list's title reads "Lurker" with the socket's light under it — on the
/// phone that vanishes the moment you open a buffer, here the column is always up, so it
/// becomes a permanent connection indicator.
///
/// The secondary column is never empty: nothing selected means `Buffer.system` — the app-wide
/// Lurker log, and NOT a network's `.server` buffer, which this codebase keeps sharply
/// distinct. It is real content and always present, where a "No Conversation Selected"
/// placeholder would be a new screen whose whole job is to be dead space.
final class BufferSplitViewController: UISplitViewController {

    private let viewModel: ChatViewModel

    /// The buffer showing in the secondary column, so the list can mark its row and a collapse
    /// can decide which column it collapses *to*.
    ///
    /// Nil until something is picked — distinct from "the column is showing the system buffer",
    /// since you can also open that deliberately, and then collapsing should leave you in it.
    private(set) var selection: BufferKey?

    private let listNav = UINavigationController()
    private let chatNav = UINavigationController()

    private var list: BufferListViewController? {
        listNav.viewControllers.first as? BufferListViewController
    }

    /// The column the buffer list lives in — what a caller holding "the navigation controller"
    /// means, and the whole stack while collapsed. `showBuffer` on it forwards back here, so nothing outside needs to know
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

    /// The sheet on screen, whichever column put it up: `dismissPresented`'s counterpart, for
    /// showing something over it rather than taking it down.
    var topPresented: UIViewController? {
        let presenters: [UIViewController] = [listNav, chatNav, self]
        return presenters.lazy.compactMap(\.presentedViewController).first
    }

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(style: .doubleColumn)
        delegate = self
        // Re-decided whenever the height class moves — rotating a Pro Max, opening a Duo.
        // Also fires as the controller first takes its traits from the window, which is what
        // settles the launch layout before anything is drawn.
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (split: BufferSplitViewController, _) in
            split.applyColumnRule()
        }

        // Tiled rather than overlaid: this is a two-pane reading app, and an overlay that
        // dims the conversation to show the list would make switching buffers modal.
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        // No hide-the-sidebar button and no swipe: the list stays up, as it does in Messages.
        // The bar also can't afford one — a ~320pt column already carrying the title, and
        // UIKit answers an overfull bar by dropping trailing items rather than overflowing
        // them. With the display-mode button present, the join "+" was measured going missing.
        presentsWithGesture = false
        displayModeButtonVisibility = .never
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

    // MARK: - When to show two columns

    /// Whether a screen with these traits gets both columns: regular in both directions.
    ///
    /// Width alone would say yes to a Pro Max in landscape, which is regular wide but compact
    /// tall — a phone on its side, not a place for a sidebar. Height is what separates it from
    /// an iPad and an opened iPhone Duo, which are regular both ways in either orientation.
    static func expands(in traits: UITraitCollection) -> Bool {
        traits.horizontalSizeClass == .regular && traits.verticalSizeClass == .regular
    }

    /// Hold the split collapsed at compact height by telling it its width is compact too.
    ///
    /// A split decides collapsing from its horizontal size class alone and offers no delegate
    /// hook to refuse an expansion, so the override is the lever. It reaches the columns as
    /// well, which is correct: collapsed, they're the phone's stack, and a phone's stack is
    /// compact wide. Only ever the width, and only ever overridden downward — the height is
    /// read, never changed, so this can't feed back into its own trigger.
    private func applyColumnRule() {
        if traitCollection.verticalSizeClass == .compact {
            traitOverrides.horizontalSizeClass = .compact
        } else if traitOverrides.contains(UITraitHorizontalSizeClass.self) {
            traitOverrides.remove(UITraitHorizontalSizeClass.self)
        }
    }

    // MARK: - Navigation

    /// Open a buffer in the conversation column.
    ///
    /// The same five things reach this that reach `UINavigationController.showBuffer` — a list
    /// tap, `/msg`, a highlight, a notification, a join — since they all go through that funnel
    /// and it forwards here. Collapsed, the columns are one merged stack and `show(.secondary)`
    /// pushes onto it, which is the phone's list-then-chat arrangement.
    func showBuffer(_ buffer: Buffer, jumpTo messageId: Int? = nil, animated: Bool) {
        // ⚠ Collapsed, `chatNav` is EMPTY — UIKit merged its contents into the primary's
        // stack, which is what `currentChat` relies on too. So none of the code below applies:
        // the early-out could never fire (nothing in `chatNav` left to match), and setting a
        // nav that isn't in the hierarchy would leave `show(.secondary)` doing the real
        // navigation on semantics we'd be guessing at. Collapsed simply IS the stack
        // arrangement, so hand it to the one place that builds it.
        if isCollapsed {
            selection = buffer.key
            list?.markSelection(buffer.key)
            listNav.setBufferStack(buffer, viewModel: viewModel, jumpTo: messageId, animated: animated)
            return
        }
        // Already reading it, with nothing to jump to — same early-out the stack version makes,
        // and for the same reason: rebuilding re-latches the unread divider, re-requests
        // history, and throws away the scroll position to arrive where we already are.
        // By `id`, which lower-cases the target: the same conversation reaches this as
        // `#Lurker` from one route and `#lurker` from another, and an exact key match would
        // miss that and rebuild the screen.
        //
        // Still recorded as the selection, though: the column *rests* on the system buffer, so
        // this is also the path for deliberately opening that one, and a buffer you opened on
        // purpose should be the one a collapse leaves you in — on an iPhone, the one a relaunch
        // restoring it lands on.
        if messageId == nil,
           let open = chatNav.viewControllers.last as? ChatViewController,
           open.buffer.key.id == buffer.key.id {
            selection = buffer.key
            show(.secondary)
            list?.markSelection(buffer.key)
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

    /// Forget which conversation is open, and drop the column back to the system buffer. For
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

    /// Nothing selected: the list, with the system buffer beside it. Where sign-in lands with
    /// no remembered buffer, and where a buffer that disappears under its reader goes — the
    /// split's answer to `popToRootViewController`, which has nothing to pop to here.
    ///
    /// Takes no `animated`: there is no transition to animate. The column is swapped outright
    /// and `show(.primary)` offers no say in it, so the parameter only misled its one caller
    /// into thinking it had asked for something.
    func showBufferList() {
        selection = nil
        chatNav.setViewControllers(
            [ChatViewController(viewModel: viewModel, buffer: .system)], animated: false
        )
        show(.primary)
        list?.markSelection(nil)
    }
}

// MARK: - Collapsing

/// Collapsing and expanding are done by hand, in both directions, so the collapsed split is
/// always exactly the phone's stack — `[list, chat]` on the list's navigation controller.
///
/// Left to UIKit, collapsing to the secondary column NESTS the conversation column's whole
/// navigation controller inside the list's stack, and expanding only un-nests what it nested.
/// Neither matches the stack the collapsed code builds (`setBufferStack`, which is the phone's
/// own), and an iPhone Duo crosses between the two in both directions whenever it's opened or
/// closed. Measured with the conversation open when the device opened: the sidebar kept
/// `[list, chat]` while the conversation column showed the system buffer; closing it again
/// pushed the whole conversation column on top of the stale chat.
///
/// So UIKit always collapses to the list, which it leaves alone, and the chat is moved
/// across — onto the list's stack on collapse, back into its column on expand.
extension BufferSplitViewController: UISplitViewControllerDelegate {

    /// Always the list: see above. The conversation follows it onto the stack in
    /// `splitViewControllerDidCollapse`, when there is one to follow.
    func splitViewController(
        _ svc: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposed: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        .primary
    }

    /// Put the conversation you were reading on top of the list — or nothing, if nothing was
    /// picked: the system buffer the column rests on isn't something anybody asked for, and
    /// the list is the right screen to land on. `selection` is the question, not "is the column
    /// showing something", which is always true.
    func splitViewControllerDidCollapse(_ svc: UISplitViewController) {
        guard let selection,
              let chat = chatNav.viewControllers.last as? ChatViewController,
              chat.buffer.key.id == selection.id,
              let list = listNav.viewControllers.first
        else { return }
        // Out of the column before onto the stack: a controller can have one parent.
        chatNav.setViewControllers([], animated: false)
        listNav.setViewControllers([list, chat], animated: false)
    }

    /// Move a conversation on the list's stack back into its column, leaving the list alone in
    /// the sidebar. With none there, the column keeps what it holds — the system buffer it rests
    /// on — and is given that if it's somehow empty.
    func splitViewControllerDidExpand(_ svc: UISplitViewController) {
        if let list = listNav.viewControllers.first,
           let chat = listNav.viewControllers.last as? ChatViewController {
            listNav.setViewControllers([list], animated: false)
            chatNav.setViewControllers([chat], animated: false)
        } else if chatNav.viewControllers.isEmpty {
            chatNav.setViewControllers(
                [ChatViewController(viewModel: viewModel, buffer: .system)], animated: false
            )
        }
    }

    func splitViewController(
        _ svc: UISplitViewController,
        displayModeForExpandingToProposedDisplayMode proposed: UISplitViewController.DisplayMode
    ) -> UISplitViewController.DisplayMode {
        .oneBesideSecondary
    }
}
