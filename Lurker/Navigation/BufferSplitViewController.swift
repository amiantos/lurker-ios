// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The app's shell once you're signed in: the buffer list beside the conversation where there's
/// room for both, and the same two screens in one navigation stack where there isn't.
///
/// This replaces the bare `PilledNavigationController` the window used to root. The invariant it
/// used to enforce by construction — *exactly one chat screen exists, with the list under it* —
/// survives, but it is enforced HERE now, because in two columns "under it" isn't a stack
/// position any more. `chat` is the whole of it: one reference, replaced rather than pushed.
///
/// **The compact layout is UIKit's job, not ours.** Collapsing merges the detail column's stack
/// into the sidebar's and expanding takes it back, which is precisely the behaviour the app had
/// before this existed — so a phone, and an iPad window dragged narrow, get the single stack
/// they always had, and neither this class nor either screen has an idiom or size-class test in
/// it. What that costs is that a conversation's screen MOVES between navigation controllers
/// while it's alive, which is why `chat` is held here rather than read out of a column's stack:
/// "which navigation controller is it in" has two answers, and neither is stable.
final class BufferSplitViewController: UISplitViewController {

    private let viewModel: ChatViewModel
    private let list: BufferListViewController
    private let sidebar: PilledNavigationController
    private let detail: PilledNavigationController

    /// The one conversation on screen, or nil when none is open. Weak: whichever stack
    /// currently holds it owns it, and a pop that deallocates it nils this for free — which is
    /// what makes "did the user go back to the list?" answerable without watching for the pop.
    private weak var chat: ChatViewController?

    init(viewModel: ChatViewModel) {
        let list = BufferListViewController(viewModel: viewModel)
        let sidebar = PilledNavigationController(rootViewController: list)
        let detail = PilledNavigationController(rootViewController: NoBufferViewController())
        self.viewModel = viewModel
        self.list = list
        self.sidebar = sidebar
        self.detail = detail
        super.init(style: .doubleColumn)

        // The buffer list wears a large title; the chat screen opts out, so it's unaffected —
        // and when the two merge into one stack, they merge into THIS bar.
        sidebar.navigationBar.prefersLargeTitles = true

        // Wired once, here, rather than at each construction site — the list reports a pick and
        // knows nothing about navigation, and this is the only thing that ever answers.
        list.onSelect = { [weak self] buffer in
            self?.showBuffer(buffer, animated: true)
        }
        // The list's search results are a cross-buffer feed like any other, so their row taps
        // mean what Highlights' and Bookmarks' do. Wired here because this is the one place
        // that knows both the feed and where a buffer opens.
        wireJump(list.searchResults, viewModel: viewModel, split: self) { [weak list] in
            list?.dismissSearch()
        }

        setViewController(sidebar, for: .primary)
        setViewController(detail, for: .secondary)
        // Side by side rather than the sidebar overlaying the conversation: the list is the
        // reason to be on an iPad at all — seeing which channels are talking while you read one
        // of them is the whole difference from the phone — and an overlay you have to summon
        // gives that back up.
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// ⚠ From `viewDidLayoutSubviews`, not only from the places that change the selection.
    /// `isCollapsed` is a fact about the CURRENT layout and is not settled until one has
    /// happened, so there is no single earlier moment that is reliably right — and a Stage
    /// Manager drag changes it without any navigation to hang a callback on. Both properties
    /// guard on equality, so the steady state is two comparisons per pass.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncSidebar()
    }

    /// Tell the list what it currently is, and which conversation is beside it.
    private func syncSidebar() {
        list.isSidebar = !isCollapsed
        list.selectedBufferKey = chat?.buffer.key.id
    }

    // MARK: - Navigation

    /// Open a buffer, with the list beside it (or under it, collapsed).
    ///
    /// Five things navigate to a buffer — picking one from the list, `/msg`, a highlight tap, a
    /// notification tap, and joining a channel — and every one of them means the same thing:
    /// *this* conversation. So they all come through here, and back always goes to the same
    /// place no matter how you arrived.
    ///
    /// The detail column is **set**, not pushed, which is what keeps one conversation on screen
    /// rather than a pile of them: `/msg` from a channel and a notification tapped while
    /// reading something else each replace the screen instead of stacking a second buffer's
    /// worth of messages and a second live subscription behind it.
    func showBuffer(_ buffer: Buffer, jumpTo messageId: Int? = nil, animated: Bool) {
        // Already reading this one, and nothing to jump to? Leave it alone. Rebuilding the
        // screen re-latches the unread divider, re-requests history, and throws away the scroll
        // position to arrive exactly where we already are — which is what tapping a
        // notification for the conversation you're looking at (a friend-online push carries no
        // messageId) would otherwise cost. A jump is a real move and still rebuilds.
        if messageId == nil, let chat, chat.buffer.key.id == buffer.key.id {
            show(.secondary)
            return
        }
        // Drop the outgoing conversation from the collapsed stack BEFORE showing the new one.
        // Expanded this is free — setting the detail column replaces it — but collapsed there
        // is only one stack, and `show(.secondary)` pushes onto it: without this, `/msg` from a
        // channel would leave the channel you left sitting behind the DM you opened, which is
        // the pile this app has never had.
        dropCollapsedChat()
        let screen = ChatViewController(viewModel: viewModel, buffer: buffer, jumpTo: messageId)
        chat = screen
        detail.setViewControllers([screen], animated: false)
        syncSidebar()
        show(.secondary)
    }

    /// The list on its own — where a launch lands when there's nothing to restore into, and
    /// where a conversation that has gone away sends its reader.
    ///
    /// Expanded, the list is already on screen and this only clears the conversation beside it.
    /// Collapsed, `show(.primary)` is the pop back to it.
    func showBufferList(animated: Bool) {
        chat = nil
        dropCollapsedChat()
        // Empty when collapsed: the placeholder is an iPad screen, and a phone's stack must not
        // inherit it (see `splitViewControllerDidCollapse`).
        let empty: [UIViewController] = isCollapsed ? [] : [NoBufferViewController()]
        detail.setViewControllers(empty, animated: false)
        syncSidebar()
        show(.primary)
    }

    /// Whether a conversation is open. `SceneDelegate` reads it to decide whether a restore has
    /// anything left to do.
    var isShowingBuffer: Bool { chat != nil }

    /// Take any conversation off the collapsed stack.
    ///
    /// A no-op expanded, where the columns are separate and the sidebar's stack is only ever the
    /// list. Collapsed, the two have been merged into `sidebar` and this trims it back to
    /// whatever sat below the conversation — the list.
    private func dropCollapsedChat() {
        guard let index = sidebar.viewControllers.firstIndex(where: { $0 is ChatViewController })
        else { return }
        sidebar.setViewControllers(Array(sidebar.viewControllers.prefix(index)), animated: false)
    }
}

// MARK: - Collapsing and expanding

extension BufferSplitViewController: UISplitViewControllerDelegate {

    /// Which column the merged stack ends on.
    ///
    /// The conversation when there is one — collapsing while reading should leave you reading,
    /// not throw you back to the list — and the list when there isn't. The second half is what
    /// keeps `NoBufferViewController` off a phone: proposed is `.secondary` whenever the detail
    /// column holds anything, and the detail column always holds *something* so that an iPad
    /// has a second column to draw.
    func splitViewController(
        _ svc: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposed: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        chat == nil ? .primary : .secondary
    }

    func splitViewController(
        _ svc: UISplitViewController,
        displayModeForExpandingToProposedDisplayMode proposed: UISplitViewController.DisplayMode
    ) -> UISplitViewController.DisplayMode {
        .oneBesideSecondary
    }

    /// ⚠ Defensive, and knowingly so. `topColumnForCollapsing` above is the documented way to
    /// say "don't put the placeholder on top", but what UIKit does with the *rest* of a column
    /// it isn't collapsing onto is not something the docs pin down — so rather than trust that
    /// the placeholder was left behind, check the merged stack and take it out if it came along.
    /// Cheap, and the failure it guards against ("No Conversation Selected" sitting over the
    /// buffer list on an iPhone) is one the single-stack app could never produce.
    func splitViewControllerDidCollapse(_ svc: UISplitViewController) {
        let merged = sidebar.viewControllers.filter { !($0 is NoBufferViewController) }
        if merged.count != sidebar.viewControllers.count {
            sidebar.setViewControllers(merged, animated: false)
        }
        detail.setViewControllers([], animated: false)
        syncSidebar()
        resyncPills()
    }

    /// The mirror: the placeholder the collapse dropped has to come back, or expanding with no
    /// conversation open would leave the second column blank.
    func splitViewControllerDidExpand(_ svc: UISplitViewController) {
        if detail.viewControllers.isEmpty {
            detail.setViewControllers([NoBufferViewController()], animated: false)
        }
        syncSidebar()
        resyncPills()
    }

    /// Both pills follow their own stack through `willShow`/`didShow`, and a collapse or expand
    /// moves screens between stacks without either being a push or a pop. Nothing tells them,
    /// so tell them: without this the sidebar keeps a conversation's name after that
    /// conversation has moved to the column beside it.
    private func resyncPills() {
        sidebar.pill.resync()
        detail.pill.resync()
    }
}

extension UIViewController {

    /// The split controller this screen lives in, if it does.
    ///
    /// Nil inside the sheets — they're presented, not parented, so `splitViewController` stops
    /// at the sheet's own navigation controller. That's correct: a sheet reaches a buffer
    /// through the screen that presented it (`leaveSheet`), never on its own.
    var bufferSplit: BufferSplitViewController? {
        splitViewController as? BufferSplitViewController
    }
}
