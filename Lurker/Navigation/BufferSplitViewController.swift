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
        // An opaque sidebar that paints the list's own ground, not the floating glass panel.
        // ⚠ `.doubleColumn` defaults to `.sidebar` (measured, iOS 27.1), which clears the
        // collection view's layer and draws glass over a secondary column running full width
        // underneath it — a washed-out grey in dark mode (#393C3E over a black column).
        // `.none` keeps the layer and tiles the columns side by side with a 1pt separator.
        primaryBackgroundStyle = .none
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
        currentChat?.isBesideList = !isCollapsed
    }

    /// A conversation screen that already knows which bar it's getting. Every screen built for
    /// the conversation column comes from here: a new one lays out its bar at load, before the
    /// next layout pass would tell it (`viewDidLayoutSubviews`).
    private func makeChat(_ buffer: Buffer, jumpTo messageId: Int? = nil) -> ChatViewController {
        let chat = ChatViewController(viewModel: viewModel, buffer: buffer, jumpTo: messageId)
        chat.isBesideList = !isCollapsed
        return chat
    }

    /// The column rule, re-asserted before every layout as well as on trait changes. The trait
    /// registration is the real trigger; this is so a launch straight into compact height (a
    /// Pro Max already on its side) can't lay out expanded once before the registration has
    /// been heard from. `applyColumnRule` no-ops when nothing would change.
    override func viewWillLayoutSubviews() {
        applyColumnRule()
        super.viewWillLayoutSubviews()
    }

    // MARK: - When to show two columns

    /// Hold the split collapsed at compact height by telling it its width is compact too, so
    /// both columns show only at regular × regular.
    ///
    /// Width alone would say yes to a Pro Max in landscape, which is regular wide but compact
    /// tall — a phone on its side, not a place for a sidebar. Height is what separates it from
    /// an iPad and an opened iPhone Duo, which are regular both ways in either orientation.
    ///
    /// A split decides collapsing from its horizontal size class alone and offers no delegate
    /// hook to refuse an expansion, so the override is the lever. It reaches the columns as
    /// well, which is correct: collapsed, they're the phone's stack, and a phone's stack is
    /// compact wide. Only ever the width, and only ever overridden downward — the height is
    /// read, never changed, so this can't feed back into its own trigger.
    private func applyColumnRule() {
        let overridden = traitOverrides.contains(UITraitHorizontalSizeClass.self)
        if traitCollection.verticalSizeClass == .compact {
            // Only when not already set: this runs before every layout, and writing an
            // override — even an unchanged one — starts a trait update.
            if !overridden { traitOverrides.horizontalSizeClass = .compact }
        } else if overridden {
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
        // ⚠ Collapsed, the conversation lives on the LIST's stack — `splitViewControllerDid
        // Collapse` moved it there, and `chatNav` is off screen and empty. So none of the code
        // below applies: the early-out could never fire, and `show(.secondary)` would be
        // navigating a column nobody can see. Collapsed simply IS the stack arrangement, so
        // hand it to the one place that builds it.
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
            // The screen was already up, so it won't appear again to record itself — and it
            // was resting until now, so it never did.
            open.recordVisit()
            show(.secondary)
            list?.markSelection(buffer.key)
            return
        }
        selection = buffer.key
        let chat = makeChat(buffer, jumpTo: messageId)
        // Set, never pushed. One conversation exists at a time — `/msg` from a channel or a
        // notification tapped mid-read must not leave a stack of live subscriptions behind a
        // back button that walks you through your own history.
        chatNav.setViewControllers([chat], animated: false)
        show(.secondary)
        list?.markSelection(buffer.key)
    }

    /// The selected buffer was renamed under its reader: keep naming it. A rename keeps the
    /// buffer and changes its key, and the chat screen follows it (see its
    /// `handleBufferDisappeared`) — this is the split following along, so its key comparisons
    /// go on matching the screen that's actually open. A no-op for any other buffer.
    func followRename(from old: BufferKey, to new: BufferKey) {
        guard selection?.id == old.id else { return }
        selection = new
        list?.markSelection(new)
    }

    /// The conversation on screen, whichever column holds it. Side by side that's never nil,
    /// since the column rests on the system buffer — which is the right answer: that screen
    /// has a composer, and is what a finished upload should insert into. Collapsed on the
    /// list, it's nil: there is no conversation on screen.
    var currentChat: ChatViewController? {
        let nav = isCollapsed ? listNav : chatNav
        return nav.topViewController as? ChatViewController
    }

    /// Forget which conversation is open, and put the column back to rest. For exit this class
    /// doesn't own: a Back tap in a collapsed split. `showBufferList` is the owned equivalent,
    /// plus getting back to the list — already done by the time a collapsed pop reaches here.
    func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        restColumn()
        list?.markSelection(nil)
    }

    /// The conversation column with nothing picked: the system buffer side by side, and empty
    /// while collapsed.
    ///
    /// Empty rather than a system screen waiting off stage, because a chat screen subscribes to
    /// state from its `viewDidLoad` and one that's been shown keeps rendering every frame while
    /// nobody can see it. `splitViewControllerDidExpand` builds the resting screen when there's
    /// somewhere to show it.
    private func restColumn() {
        chatNav.setViewControllers(
            isCollapsed ? [] : [makeChat(.system)],
            animated: false
        )
    }

    /// Nothing selected: the list, with the system buffer beside it, or the list alone when
    /// collapsed. Where a buffer that disappears under its reader goes.
    ///
    /// Collapsed, the conversation was put on the list's stack by hand (`setBufferStack`, or
    /// `splitViewControllerDidCollapse`), so it's popped by hand rather than trusting
    /// `show(.primary)` to find something UIKit never pushed.
    ///
    /// Takes no `animated`: side by side there is no transition to animate — the column is
    /// swapped outright and `show(.primary)` offers no say in it.
    func showBufferList() {
        selection = nil
        if isCollapsed {
            listNav.popToRootViewController(animated: true)
        } else {
            show(.primary)
        }
        restColumn()
        list?.markSelection(nil)
    }

    /// True while the collapse and expand callbacks are moving a chat screen between the two
    /// navigation controllers — which, for a moment, leaves it with neither. Read by the chat's
    /// back-out bookkeeping, which would otherwise take that moment for the reader leaving.
    private(set) var isRearranging = false
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
        isRearranging = true
        defer { isRearranging = false }
        // Out of the column either way — onto the stack if it's the conversation, and dropped
        // if it's only the resting system screen, which would otherwise go on rendering every
        // frame off screen (see `restColumn`). Out before onto: a controller has one parent.
        let chat = chatNav.viewControllers.last as? ChatViewController
        chatNav.setViewControllers([], animated: false)
        guard let selection, let chat, chat.buffer.key.id == selection.id,
              let list = listNav.viewControllers.first
        else { return }
        listNav.setViewControllers([list, chat], animated: false)
    }

    /// Move a conversation on the list's stack back into its column, leaving the list alone in
    /// the sidebar. With none there, the column keeps what it holds — the system buffer it rests
    /// on — and is given that if it's somehow empty.
    func splitViewControllerDidExpand(_ svc: UISplitViewController) {
        isRearranging = true
        defer { isRearranging = false }
        if let list = listNav.viewControllers.first,
           let chat = listNav.viewControllers.last as? ChatViewController {
            listNav.setViewControllers([list], animated: false)
            chatNav.setViewControllers([chat], animated: false)
        } else if chatNav.viewControllers.isEmpty {
            chatNav.setViewControllers([makeChat(.system)], animated: false)
        }
    }

    func splitViewController(
        _ svc: UISplitViewController,
        displayModeForExpandingToProposedDisplayMode proposed: UISplitViewController.DisplayMode
    ) -> UISplitViewController.DisplayMode {
        .oneBesideSecondary
    }
}
