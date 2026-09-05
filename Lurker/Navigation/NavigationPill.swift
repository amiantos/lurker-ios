// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// What the pill reads on a given screen.
struct PillContent: Equatable {
    var title: String
    var status: StatusLight
    /// VoiceOver's description of what tapping does — it differs per screen.
    var hint: String
}

/// A screen that wears the status pill.
///
/// The screen owns the *content* (only it knows which buffer it is showing and which
/// network's state that buffer follows) and the *action*; it does not own the view.
@MainActor
protocol PillPresenting: UIViewController {
    var pillContent: PillContent { get }
    func pillTapped()
}

/// The one status pill, for the whole navigation stack.
///
/// It used to be each screen's `navigationItem.titleView`, which meant two pills: the
/// outgoing screen's slid away and the incoming screen's slid in, while the bar *buttons*
/// either side of them stayed put and morphed. iOS 26 gives bar buttons that morph because
/// they live in glass containers the bar keeps across a push (and `UIBarButtonItem.identifier`
/// exists to match them up by hand). The title area is not in that system, and a centred
/// pill cannot join it: `centerItemGroups` is the only centre slot UIKit offers and it
/// overflows into the trailing group at compact width, in every `UINavigationItem.style`.
///
/// So this doesn't morph — it never moves. One pill, owned by the bar rather than by either
/// screen, with the screens changing underneath it. Continuity by construction rather than by
/// interpolating between two views, which is also why it can't drift out of sync: there is
/// only ever the one.
@MainActor
final class NavigationPill: NSObject, UINavigationControllerDelegate {

    /// Centre of the bar's *small-title row*, measured from the bar's top.
    ///
    /// Deliberately not `centerYAnchor`: a bar showing a large title is ~96pt tall and its
    /// centre lands in the middle of that large title, which would drag the pill down the
    /// moment the buffer list appeared and float it back up on every push.
    ///
    /// Half the standard bar height, which UIKit picks by IDIOM rather than by width: 44pt on
    /// iPhone, 50pt on iPad. Read once, at `attach`, because that is exactly as often as it can
    /// change — an iPad window dragged narrow goes compact in its size classes but stays `.pad`,
    /// and its bar stays 50.
    private static func smallTitleRowCenter(for bar: UINavigationBar) -> CGFloat {
        bar.traitCollection.userInterfaceIdiom == .pad ? 25 : 22
    }

    private weak var navigationController: UINavigationController?

    /// Hide the pill regardless of what's on the stack, for as long as something is covering
    /// the screen it belongs to.
    ///
    /// Search is the case this exists for. It presents *over* the buffer list without changing
    /// the stack, so the bar — and this pill, which is a subview of it — stays put underneath,
    /// leaving "Lurker" floating above a search field that has nothing to do with it.
    ///
    /// A flag rather than a one-off `setVisible(false)` call, because visibility is re-derived
    /// on every push, pop and settle: tapping a result navigates to a buffer *before* search
    /// dismisses, so `willShow` would put the pill straight back while the results are still on
    /// screen. This outranks all of that, and `wantsVisible` remembers what the stack asked for
    /// so lifting it restores the right answer rather than assuming "visible".
    var isSuppressed = false {
        didSet {
            guard isSuppressed != oldValue else { return }
            UIView.animate(withDuration: Self.suppressionFade) { self.applyVisibility() }
        }
    }

    /// What the *stack* last asked for, before suppression is taken into account.
    private var wantsVisible = false

    private static let suppressionFade: TimeInterval = 0.2

    private lazy var pill = BufferTitleButton(onTap: { [weak self] in
        // Routed live rather than captured: the pill outlives every screen, so the tap
        // belongs to whichever one is on top when it happens.
        (self?.navigationController?.topViewController as? PillPresenting)?.pillTapped()
    })

    /// Put the pill in the bar and start following the stack.
    func attach(to nav: UINavigationController) {
        navigationController = nav
        nav.delegate = self

        let bar = nav.navigationBar
        pill.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            pill.centerYAnchor.constraint(
                equalTo: bar.topAnchor, constant: Self.smallTitleRowCenter(for: bar)),
        ])

        // Sync to whatever is already on the stack. The launch path builds its screens before
        // the window exists — which is what loads this controller's view and runs `attach` —
        // so the first screen is in place well before there's a delegate to hear about it,
        // and would otherwise sit under a blank, invisible pill until the second navigation.
        syncToTop(animated: false)
    }

    /// Re-read the stack from outside a push or a pop.
    ///
    /// Exists for the split view's collapse and expand, which move screens BETWEEN stacks: no
    /// navigation happens, so neither `willShow` nor `didShow` fires, and a pill left to its
    /// own devices keeps the name of a conversation that is now in the column beside it.
    func resync() {
        syncToTop(animated: false)
    }

    /// Match the pill to the screen currently on top: its content, and whether it appears at
    /// all. The sign-in screen doesn't wear one.
    private func syncToTop(animated: Bool) {
        guard let presenting = navigationController?.topViewController as? PillPresenting else {
            setVisible(false, animated: animated)
            return
        }
        show(presenting.pillContent, animated: animated)
        setVisible(true, animated: animated)
    }

    /// Re-read a screen's content and show it, if that screen is the one on top.
    ///
    /// Both screens call this from their state-change path, and both are subscribed to state
    /// that keeps arriving while they sit *under* a pushed chat screen — hence the guard.
    /// Without it, a message arriving in some other channel would let the buffer list, still
    /// live below, relabel the pill of the conversation you're reading.
    func refresh(from vc: PillPresenting) {
        guard vc === navigationController?.topViewController else { return }
        show(vc.pillContent, animated: true)
    }

    private func show(_ content: PillContent, animated: Bool) {
        let apply = { self.pill.update(title: content.title, status: content.status, hint: content.hint) }

        // Cross-fade only while a push or pop is actually running, and only when something
        // is really changing — `update` no-ops otherwise, and a cross-dissolve over an
        // unchanged view still costs two snapshots. Outside a transition the light changing
        // colour should just change colour; it isn't a navigation event.
        guard animated, pill.wouldChange(title: content.title, status: content.status, hint: content.hint),
              let coordinator = navigationController?.transitionCoordinator, coordinator.isAnimated
        else {
            apply()
            return
        }
        UIView.transition(
            with: pill, duration: coordinator.transitionDuration,
            options: [.transitionCrossDissolve, .allowUserInteraction], animations: apply
        )
    }

    private func setVisible(_ visible: Bool, animated: Bool) {
        wantsVisible = visible
        guard animated, let coordinator = navigationController?.transitionCoordinator, coordinator.isAnimated else {
            applyVisibility()
            return
        }
        UIView.animate(withDuration: coordinator.transitionDuration) { self.applyVisibility() }
    }

    /// The one place the pill's alpha is decided: what the stack wants, minus anything
    /// currently covering it.
    private func applyVisibility() {
        let visible = wantsVisible && !isSuppressed
        // Interaction tracks visibility so an invisible pill can't still be tapped — it sits
        // over the bar's whole centre, which is otherwise dead space someone may well press.
        // Doubly so while suppressed, where the thing over it is taking touches of its own.
        pill.isUserInteractionEnabled = visible
        pill.alpha = visible ? 1 : 0
    }

    // MARK: - UINavigationControllerDelegate

    /// The incoming screen's content is shown *here*, not from its own `viewWillAppear`.
    ///
    /// A screen that pushes its title on appear pushes it before the transition has drawn a
    /// frame, so the pill would read the new buffer's name while the old screen was still
    /// sliding out. This runs inside the same transition, so the text crosses over with it.
    ///
    /// It also covers the pop: the buffer list's content is fixed except for the light, so it
    /// has no state change on the way back and would otherwise arrive still wearing the
    /// channel's name.
    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        // UIKit adds its own item views to the bar on every push; re-assert our place on top
        // of them rather than trusting the order we were added in to hold.
        navigationController.navigationBar.bringSubviewToFront(pill)

        // Reads `viewController` rather than `topViewController`, which is the same thing for
        // a push but not for an *interactive* pop: the gesture can be abandoned, and UIKit
        // then calls this again with the screen we never left.
        guard let presenting = viewController as? PillPresenting else {
            setVisible(false, animated: animated)
            return
        }
        show(presenting.pillContent, animated: animated)
        setVisible(true, animated: animated)
    }

    /// Settle on whatever actually ended up on top.
    ///
    /// `willShow` announces an *intent*, and a swipe-back can be abandoned halfway: UIKit
    /// says it will show the buffer list, the gesture is released short of the threshold, and
    /// the chat screen stays. Without this the pill would keep the name it changed to for a
    /// navigation that never happened.
    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        syncToTop(animated: false)
    }
}

extension UIViewController {

    /// The pill, if this screen is in a stack that has one. Nil inside the sheets — the
    /// highlights list runs in its own throwaway navigation controller, which has no pill and
    /// shouldn't grow one.
    var navigationPill: NavigationPill? {
        (navigationController as? PilledNavigationController)?.pill
    }
}

/// The app's navigation controller. Exists to own the pill for the stack's whole life, which
/// is the point — a pill owned by a screen dies with that screen.
///
/// ⚠ The pill *is* this controller's `delegate`, and its entire sync mechanism is
/// `willShow`/`didShow`. Setting `delegate` on this controller from anywhere else strands the
/// pill on whatever screen it last saw. If something ever needs the delegate too, forward to
/// `pill` rather than replace it.
final class PilledNavigationController: UINavigationController {

    let pill = NavigationPill()

    /// Make that coupling fail loudly in development instead of silently in the UI.
    ///
    /// Guarding inside `attach` would only catch a delegate set *before* it, and `attach` runs
    /// from `viewDidLoad` — so in practice it would catch nothing. The direction that can
    /// actually happen is a delegate assigned afterwards, which this sees.
    override var delegate: (any UINavigationControllerDelegate)? {
        didSet {
            assert(
                delegate === pill,
                "PilledNavigationController's delegate belongs to its NavigationPill. Forward to "
                    + "`pill` from your own delegate rather than replacing it, or the pill stops "
                    + "tracking the stack."
            )
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        pill.attach(to: self)
    }
}
