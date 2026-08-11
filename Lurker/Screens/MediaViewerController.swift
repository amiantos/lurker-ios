// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import AVKit
import LurkerKit
import UIKit

/// Full-screen image viewing — the thing iOS has never had, and which three separate parts of
/// link previews turned out to need.
///
/// The message list can only ever show a picture small and, in a mosaic, cropped: every
/// attachment's height has to be known from its metadata so an arriving image can't grow a row
/// under the reader's thumb, and cells are sized in a phone-width column. That constraint is
/// right for a log and wrong for looking at something. Before this, "look at it properly" meant
/// leaving the app for Safari — which loses the message you were reading, and can't show a
/// proxied image at all without re-fetching it from the origin.
///
/// It answers three things at once:
///
///   - **A cropped tile is recoverable.** The mosaic fills its cells, which is what makes a
///     group's height a function of the count alone; here the whole frame is visible.
///   - **A GIF plays at its own size.** Inline it played inside a box smaller than itself, which
///     is what sent this feature back to the drawing board.
///   - **A message's other pictures are reachable.** It opens as a GALLERY over every image in
///     the message, positioned on the one that was tapped, which is what the web has always done.
///
/// ⚠ Autoplay IS right here, unlike inline. Opening the viewer is an explicit request to look at
/// one picture; there is exactly one animation on screen, and the reader asked for it.
final class MediaViewerController: UIViewController {

    private let previews: [LinkPreview]
    private let model: ChatViewModel
    private var index: Int

    private lazy var pages: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.sectionInset = .zero
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.isPagingEnabled = true
        view.showsHorizontalScrollIndicator = false
        view.backgroundColor = .clear
        view.contentInsetAdjustmentBehavior = .never
        view.dataSource = self
        view.delegate = self
        view.register(MediaPageCell.self, forCellWithReuseIdentifier: MediaPageCell.reuseID)
        view.register(
            MediaPlayerPageCell.self, forCellWithReuseIdentifier: MediaPlayerPageCell.reuseID)
        return view
    }()

    private let counter = UILabel()
    private let closeButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)

    init(previews: [LinkPreview], startAt index: Int, model: ChatViewModel) {
        self.previews = previews
        self.model = model
        self.index = min(max(0, index), max(0, previews.count - 1))
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Its own black rather than a system background: a picture is judged against what is
        // behind it, and a viewer that follows the light/dark setting shows the same photograph
        // two different ways.
        view.backgroundColor = .black

        counter.textColor = .white
        counter.font = .preferredFont(forTextStyle: .footnote)
        counter.adjustsFontForContentSizeCategory = true
        counter.textAlignment = .center
        counter.isAccessibilityElement = false

        // ⚠ Both buttons carry their own scrim. A white glyph over an unknown picture is
        // invisible against a white one — and this viewer exists precisely to show pictures we
        // know nothing about. The system does the same thing over photo content, for the same
        // reason.
        for button in [closeButton, shareButton] {
            button.tintColor = .white
            var configuration = UIButton.Configuration.plain()
            configuration.background.backgroundColor = UIColor.black.withAlphaComponent(0.4)
            configuration.background.cornerRadius = 16
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: 8, leading: 8, bottom: 8, trailing: 8)
            button.configuration = configuration
        }
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.accessibilityLabel = "Close"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        shareButton.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        // ⚠ The ORIGIN address, not our proxy path. A proxy URL is authenticated and signed for
        // this session, so sharing one hands over something nobody else can open — and it leaks
        // a bearer-gated path. What a person means by "share this picture" is the address it
        // came from.
        shareButton.accessibilityLabel = "Share link"
        shareButton.addTarget(self, action: #selector(share), for: .touchUpInside)

        // ⚠⚠ Three separate views, NOT a bar. They were a full-width `UIStackView` pinned across
        // the top, and a container is a touch target for its whole rectangle whether or not
        // anything is drawn in it — so an invisible full-width band sat over the top of the
        // screen swallowing every tap in that strip.
        //
        // `AVPlayerViewController`'s controls overlay is VIEW-sized rather than video-sized, so
        // its top row — Picture-in-Picture, AirPlay — lands directly under that band and became
        // unusable. Hiding the buttons inside the stack did nothing, because the bar was never
        // the buttons: it was the container they sat in. Constrained individually, the only
        // thing that can intercept a touch is a button the reader can actually see.
        counter.isUserInteractionEnabled = false

        for subview in [pages, closeButton, counter, shareButton] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            pages.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pages.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pages.topAnchor.constraint(equalTo: view.topAnchor),
            pages.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            closeButton.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            closeButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            shareButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            shareButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            counter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            counter.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
        ])

        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(close))
        // ⚠ Loses to a double-tap-to-zoom, or zooming in always dismisses on the first tap of
        // the pair. The page cell owns the double tap; this waits to see if one is coming.
        dismissTap.require(toFail: doubleTapOfVisiblePage())
        // ⚠⚠ And it must never see a touch that landed on the player. A gesture recognizer on an
        // ANCESTOR still receives touches delivered to its descendants, and `cancelsTouchesInView`
        // defaults to true — so this recogniser sat above `AVPlayerViewController`'s controls and
        // ate the taps meant for them, then dismissed the viewer for good measure. Play, scrub,
        // PiP and AirPlay were all unreachable, and none of it was visible in the layout.
        dismissTap.delegate = self
        pages.addGestureRecognizer(dismissTap)

        let swipe = UIPanGestureRecognizer(target: self, action: #selector(pan))
        swipe.delegate = self
        view.addGestureRecognizer(swipe)

        updateChrome()
    }

    /// The page size, set BEFORE the pass that lays the pager out rather than after it.
    ///
    /// ⚠⚠ A privacy fix, not a layout tidy-up. Assigned in `viewDidLayoutSubviews`, this arrived
    /// one pass too late: the first one ran at the flow layout's default 50x50, and at that size
    /// every page fits on screen at once — so the collection view dequeued ALL of them. Each page
    /// starts an `AVURLAsset.load` on its source, so opening a message that holds a clip beside a
    /// picture reached out to that clip's third-party origin the instant the viewer appeared,
    /// before the reader had swiped anywhere near it. `LinkPreview.inlinePicture` states the
    /// opposite as this feature's rule: a clip's bytes "are fetched only on a deliberate tap".
    /// Measured rather than reasoned — 6 pages dequeued at the default size, 1 at page size.
    ///
    /// From `view.bounds` rather than the screen's, because the pager is pinned to this view's
    /// four edges and those are not the same rectangle in a split view or Stage Manager. It
    /// tracks a rotation for the same reason the old assignment did, and is guarded on a change
    /// because assigning `itemSize` invalidates the layout.
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        guard let layout = pages.collectionViewLayout as? UICollectionViewFlowLayout,
            view.bounds.size != .zero, layout.itemSize != view.bounds.size
        else { return }
        layout.itemSize = view.bounds.size
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Only before the first paint: doing it on every layout pass would fight the reader's
        // own scrolling, and a rotation is handled by the same first-run branch re-arming.
        if pages.contentOffset.x == 0, index > 0, pages.bounds.width > 0 {
            pages.setContentOffset(CGPoint(x: CGFloat(index) * pages.bounds.width, y: 0),
                                   animated: false)
        }
    }

    private func doubleTapOfVisiblePage() -> UIGestureRecognizer {
        let placeholder = UITapGestureRecognizer()
        placeholder.numberOfTapsRequired = 2
        // ⚠ It exists only to be failed against, so it must not affect touch delivery on its way
        // there — the same trap as the dismiss tap, one step quieter, because a recogniser with
        // no action still cancels touches to the views beneath it by default.
        placeholder.cancelsTouchesInView = false
        placeholder.delegate = self
        pages.addGestureRecognizer(placeholder)
        return placeholder
    }

    /// Keep our own chrome out of the player's way.
    ///
    /// ⚠⚠ `AVPlayerViewController` draws its own controls, and its top-right corner is where it
    /// puts Picture-in-Picture and AirPlay — exactly where our share button sits. Two overlays
    /// stacked in the same corner, one of which auto-hides and one of which does not, and the
    /// reader can reach neither reliably.
    ///
    /// So on a player page ALL of ours gets out of the way, close button included: the system
    /// player draws its own dismiss, and two X buttons in one corner is worse than either.
    ///
    /// ⚠⚠ Which makes the player's dismiss the only way out of a video page — the swipe stands
    /// down there too, because a scrubber is a horizontal drag inside a vertically-dismissing
    /// view. `MediaPlayerPageCell` therefore reports its player's dismissal back here and this
    /// closes with it. Without that, a message holding ONE video would be a screen with no exit:
    /// in a longer gallery you could swipe to a picture and use its X, but a lone clip has
    /// nothing to swipe to.
    ///
    /// ⚠ The cost is that a video can't be shared from in here. The address is still in the
    /// message, and losing a button beats losing the player's own controls.
    private func updateChrome() {
        let isPlayer = previews.indices.contains(index) && previews[index].kind != .image
        counter.text = previews.count > 1 ? "\(index + 1) of \(previews.count)" : nil
        counter.isHidden = isPlayer
        shareButton.isHidden = isPlayer
        closeButton.isHidden = isPlayer
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func share() {
        guard let url = URL(string: previews[index].url) else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = shareButton
        present(sheet, animated: true)
    }

    /// Swipe down to dismiss, with the picture following the finger — the gesture every other
    /// full-screen viewer on the platform uses, so it is the one a reader will try first.
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .changed:
            pages.transform = CGAffineTransform(translationX: 0, y: max(0, translation.y))
            // Fading the ground as it goes is what makes it read as dismissal rather than as
            // the picture having come loose.
            view.backgroundColor = UIColor.black.withAlphaComponent(
                1 - min(0.6, max(0, translation.y) / 400))
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: view).y
            if translation.y > 120 || velocity > 900 {
                dismiss(animated: true)
                return
            }
            UIView.animate(withDuration: 0.25) {
                self.pages.transform = .identity
                self.view.backgroundColor = .black
            }
        default:
            break
        }
    }
}

extension MediaViewerController: UICollectionViewDataSource, UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        previews.count
    }

    func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let preview = previews[indexPath.item]
        if preview.kind == .image {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: MediaPageCell.reuseID, for: indexPath) as! MediaPageCell
            cell.configure(preview, model: model)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: MediaPlayerPageCell.reuseID, for: indexPath)
            as! MediaPlayerPageCell
        cell.configure(
            preview, model: model, host: self,
            openExternally: { [weak self] url in
                self?.dismiss(animated: true) { UIApplication.shared.open(url) }
            },
            onPlayerDismissed: { [weak self] in self?.dismiss(animated: true) })
        return cell
    }

    /// ⚠ A page leaving the screen stops playing, and this is not politeness. Without it,
    /// swiping to the next picture leaves the previous video's audio running underneath it —
    /// and dismissing the viewer entirely leaves it playing over the message list, with no
    /// visible control anywhere to stop it.
    func collectionView(
        _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        (cell as? MediaPlayerPageCell)?.stop()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        for cell in pages.visibleCells { (cell as? MediaPlayerPageCell)?.stop() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pages, pages.bounds.width > 0 else { return }
        let page = Int((scrollView.contentOffset.x / pages.bounds.width).rounded())
        guard page != index, previews.indices.contains(page) else { return }
        index = page
        updateChrome()
    }
}

extension MediaViewerController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    /// ⚠⚠ Tap-to-dismiss never sees a touch inside a player page. Everything the system player
    /// draws — the transport, the scrubber, PiP, AirPlay — lives in views below this recogniser,
    /// which would otherwise intercept the tap AND cancel it on its way to the control.
    ///
    /// Tested by asking the view under the touch, not by asking which page index is showing: a
    /// player's controls extend over the whole page, and mid-swipe two pages are on screen at
    /// once.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer is UITapGestureRecognizer else { return true }
        var view: UIView? = touch.view
        while let current = view {
            if current is MediaPlayerPageCell { return false }
            view = current.superview
        }
        return true
    }

    /// ⚠ The dismiss pan stands down while the picture is zoomed in, or panning around a
    /// magnified image would throw the viewer away instead of moving the image. It also stands
    /// down for a mostly-horizontal drag, which is the reader paging between pictures.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }
        // ⚠ Not over a player. Its scrubber is a horizontal drag inside a vertically-dismissing
        // view, and a reader nudging the playhead would throw the viewer away instead. The close
        // button is the way out of a video page; every other page keeps the swipe.
        if pages.visibleCells.contains(where: { $0 is MediaPlayerPageCell }) { return false }
        let visible = pages.visibleCells.compactMap { $0 as? MediaPageCell }.first
        if let visible, visible.isZoomed { return false }
        let translation = pan.translation(in: view)
        return abs(translation.y) > abs(translation.x)
    }
}

/// One picture, zoomable.
private final class MediaPageCell: UICollectionViewCell {
    static let reuseID = "MediaPage"

    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private var path: String?

    var isZoomed: Bool { scroll.zoomScale > scroll.minimumZoomScale + 0.01 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.maximumZoomScale = 4
        scroll.minimumZoomScale = 1
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scroll)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func configure(_ preview: LinkPreview, model: ChatViewModel) {
        path = preview.src
        imageView.accessibilityLabel = preview.title ?? "Image"
        imageView.isAccessibilityElement = true
        guard let path = preview.src else { return }

        // The still first, from the cache the list already filled — so the picture is on screen
        // the instant the viewer opens rather than after a round trip.
        PreviewImageLoader.shared.load(path: path, using: model) { [weak self] image in
            guard self?.path == path else { return }
            self?.imageView.image = image
        }
        // ⚠ Autoplay HERE, and only here. Inline it would mean every animation in scrollback
        // decoding its whole frame set; in the viewer there is one picture on screen and the
        // reader opened it deliberately.
        guard PreviewImageLoader.shared.isAnimated(path) else { return }
        PreviewImageLoader.shared.loadAnimated(path: path, using: model) { [weak self] animated in
            guard self?.path == path, let animated else { return }
            self?.imageView.image = animated
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // ⚠ Frames released with the page. A gallery of animations would otherwise accumulate
        // every frame set the reader had paged past, which is the memory problem opt-in
        // playback exists to avoid — reintroduced one swipe at a time.
        path = nil
        imageView.image = nil
        scroll.setZoomScale(1, animated: false)
    }

    @objc private func toggleZoom() {
        scroll.setZoomScale(isZoomed ? scroll.minimumZoomScale : 2.5, animated: true)
    }
}

extension MediaPageCell: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}


/// A video or audio page: the system player, with an honest failure state behind it.
///
/// `AVPlayerViewController` rather than a hand-rolled transport, because it brings scrubbing,
/// volume, AirPlay, Picture-in-Picture and the full-screen affordance that people already know —
/// none of which is worth reimplementing to look slightly different.
private final class MediaPlayerPageCell: UICollectionViewCell {
    static let reuseID = "MediaPlayerPage"

    private var controller: AVPlayerViewController?
    private var path: String?
    /// The in-flight source fetch, so teardown can stop it. See `stop()`.
    private var loadTask: Task<Void, Never>?
    private let spinner = UIActivityIndicatorView(style: .large)
    private let fallback = UIStackView()
    private let fallbackLabel = UILabel()
    private let fallbackButton = UIButton(type: .system)
    /// The way out while there is no player to provide one. See `showsOwnExit`.
    private let closeButton = UIButton(type: .system)
    private var openExternally: ((URL) -> Void)?
    private var onPlayerDismissed: (() -> Void)?
    private var originURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        spinner.color = .white

        fallbackLabel.textColor = .white
        fallbackLabel.textAlignment = .center
        fallbackLabel.numberOfLines = 0
        fallbackLabel.font = .preferredFont(forTextStyle: .callout)
        fallbackLabel.adjustsFontForContentSizeCategory = true
        fallbackButton.setTitle("Open in Browser", for: .normal)
        fallbackButton.addTarget(self, action: #selector(openOutside), for: .touchUpInside)
        closeButton.setTitle("Close", for: .normal)
        closeButton.addTarget(self, action: #selector(closeViewer), for: .touchUpInside)
        // ⚠ ONE stack holding all four, rather than a centred spinner and a centred fallback.
        // Two views pinned to the same centre are two views in the same place: the moment the
        // exit needed to appear during LOADING, un-hiding its container also un-hid the message
        // and "Open in Browser", and they drew straight over the spinner. A stack lays its
        // children out in sequence, so nothing can overlap whatever combination is showing.
        fallback.axis = .vertical
        fallback.spacing = 12
        fallback.alignment = .center
        fallback.isHidden = true
        fallback.addArrangedSubview(spinner)
        fallback.addArrangedSubview(fallbackLabel)
        fallback.addArrangedSubview(fallbackButton)
        fallback.addArrangedSubview(closeButton)
        fallback.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(fallback)

        NSLayoutConstraint.activate([
            fallback.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            fallback.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            fallback.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentView.leadingAnchor, constant: 32),
            fallback.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor, constant: -32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func configure(
        _ preview: LinkPreview, model: ChatViewModel, host: UIViewController,
        openExternally: @escaping (URL) -> Void,
        onPlayerDismissed: @escaping () -> Void
    ) {
        // ⚠⚠ THE ORIGIN URL, never `preview.src`, and this cell deliberately ignores that field
        // even when one is present. The server stopped minting a byte URL for video and audio
        // (see "Link previews & inline media" in the lurker repo's docs/SELF_HOSTING.md): a card
        // that renders by itself must not report the reader to a stranger's host, but pressing
        // play is a deliberate act, and hiding an address at that moment conceals nothing that
        // opening the link reveals a second later. Relaying whole clips through the instance
        // bought no privacy anyone kept and cost it a great deal of memory.
        //
        // ⚠ Preferring `src` when it happens to exist would be the obvious defensive spelling
        // and it is a TRAP: a descriptor minted before that server change may still be in memory
        // on a running client, and its token now answers 404 — so the defensive branch is the
        // one that reliably fails.
        let source = preview.url
        path = source
        self.openExternally = openExternally
        self.onPlayerDismissed = onPlayerDismissed
        originURL = URL(string: preview.url)
        showLoading()

        loadTask?.cancel()
        loadTask = Task { @MainActor in
            // ⚠ STREAMED, not staged. `playableMediaURL` hands an absolute http(s) address
            // straight back, so AVURLAsset does its own ranged reads and playback starts on the
            // first frames rather than after the whole file lands. The download-to-Caches path
            // in that function is for bearer-gated proxy paths, which this no longer produces.
            // ⚠ No Authorization header goes anywhere near this: it is a third-party address by
            // construction, and `mediaRequest` is never reached on the absolute branch.
            // ⚠ The reuse token is checked FIRST and on its own. Folded into the same `guard`
            // as the success condition, a completion arriving for a page that had already moved
            // on took the failure branch and painted "couldn't be loaded" over whatever the cell
            // had become. A stale answer is not a failed one; it is nobody's answer.
            guard !Task.isCancelled, self.path == source else { return }
            guard let url = await model.playableMediaURL(path: source, mime: preview.mime) else {
                self.showFallback("There's nothing to play here.")
                return
            }
            guard !Task.isCancelled, self.path == source else { return }
            let asset = AVURLAsset(url: url)
            // ⚠ ASKED, not assumed. The server proxies any `video/*`, and this platform decodes
            // neither webm nor ogg — both common enough on IRC to matter. A player that spins
            // forever is a worse answer than a sentence and a button.
            //
            // ⚠⚠ A THROWN error is a different answer from `isPlayable == false`, and `try?`
            // collapsed the two into one sentence about the format. Since the bytes started
            // coming from the origin rather than from this instance, reaching them is the part
            // that fails: a 404, a DNS or TLS failure, and — most likely of all — a host that
            // 403s a hotlinked request. Every one of those told the reader their phone couldn't
            // decode the file, which sends them to check a setting that isn't the problem. The
            // distinction costs a `do`/`catch` and the string that used to be here.
            let playable: Bool
            do {
                playable = try await asset.load(.isPlayable)
            } catch {
                guard !Task.isCancelled, self.path == source else { return }
                self.showFallback("This couldn't be loaded.")
                return
            }
            guard !Task.isCancelled, self.path == source else { return }
            guard playable else {
                self.showFallback("This format can't be played on iOS.")
                return
            }
            self.attachPlayer(AVPlayer(playerItem: AVPlayerItem(asset: asset)), host: host)
        }
    }

    private func attachPlayer(_ player: AVPlayer, host: UIViewController) {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = self
        configureAudioSession()
        controller.videoGravity = .resizeAspect
        // Audio has no picture, so the player draws its own placeholder rather than a black void.
        controller.view.backgroundColor = .clear
        host.addChild(controller)
        controller.view.frame = contentView.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(controller.view)
        controller.didMove(toParent: host)
        self.controller = controller
        // The player draws its own dismiss now, so ours steps aside — verified on device.
        hideOwnExit()
        player.play()
    }

    /// Waiting on the bytes: a spinner and the way out, and nothing else.
    private func showLoading() {
        spinner.startAnimating()
        spinner.isHidden = false
        fallbackLabel.isHidden = true
        fallbackButton.isHidden = true
        closeButton.isHidden = false
        fallback.isHidden = false
    }

    private func showFallback(_ message: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        fallbackLabel.text = message
        fallbackLabel.isHidden = false
        // Hidden when the origin address won't parse — which is exactly why the exit below it
        // is unconditional rather than the fallback's only control.
        fallbackButton.isHidden = originURL == nil
        closeButton.isHidden = false
        fallback.isHidden = false
    }

    /// ⚠⚠ A page with no player must carry its own way out.
    ///
    /// The viewer hides ALL of its chrome on a player page — close, counter and share — because
    /// the system player draws its own dismiss, and the swipe stands down there because a
    /// scrubber is a horizontal drag inside a vertically-dismissing view. That trade is sound
    /// exactly as long as a player exists. It does not exist in three states, and each one was a
    /// screen with no exit:
    ///
    ///   - the clip is still being ASKED ABOUT (nothing is downloaded any more — clips stream
    ///     from the origin — but the `isPlayable` probe is a round trip to a stranger's host, so
    ///     on a slow link this is still a spinner and nothing else),
    ///   - it could not be REACHED — a 404, a TLS failure, a host that refuses a hotlink,
    ///   - the format is one AVFoundation will not open — webm and ogg, both ordinary on IRC —
    ///     where the only other control is "Open in Browser", which leaves the app entirely, and
    ///     which `showFallback` itself hides when the origin URL will not parse.
    ///
    /// Hidden again the moment a player attaches, so the two never both offer an exit.
    /// Make this app's audio a PLAYBACK session, so a video can actually be heard.
    ///
    /// ⚠⚠ With no category set, the process default applies — and that one obeys the ring/silent
    /// switch, so a clip plays silently for anyone with silent mode on, which is most people most
    /// of the time. It reads as "this video has no sound" rather than as a device setting,
    /// because nothing on screen mentions the switch. `.playback` is the category that says this
    /// audio IS the point, and it is what every video app uses.
    ///
    /// ⚠ Activating it interrupts whatever the reader was listening to, which is the accepted
    /// bargain for a video somebody deliberately opened — and `stop()` deactivates with
    /// `notifyOthersOnDeactivation` so their music resumes afterwards rather than staying
    /// stopped.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    private func hideOwnExit() {
        spinner.stopAnimating()
        fallback.isHidden = true
    }

    @objc private func openOutside() {
        guard let originURL else { return }
        openExternally?(originURL)
    }

    @objc private func closeViewer() {
        onPlayerDismissed?()
    }

    /// Stop and tear down. Called when the page scrolls away and when the viewer closes.
    ///
    /// ⚠⚠ Clears `path` and cancels the load, and both matter. The awaited step is now an
    /// `isPlayable` probe rather than a whole download — clips stream from the origin — but it
    /// is still a suspension point, and dismissing across it left a Task that
    /// resumed afterwards, passed its reuse check — `path` was still set, because only
    /// `prepareForReuse` cleared it and a dismissed cell is never dequeued again — and called
    /// `addChild` plus `play()` on a torn-down view controller. Audio over the message list with
    /// no control anywhere to stop it, which is the exact outcome this method exists to prevent.
    /// The Task also held the viewer alive through its captured `host`.
    func stop() {
        // Hand the audio system back before tearing the player down, so whatever was playing
        // before the reader opened this can pick up again.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        loadTask?.cancel()
        loadTask = nil
        path = nil
        controller?.player?.pause()
        controller?.player = nil
        controller?.willMove(toParent: nil)
        controller?.view.removeFromSuperview()
        controller?.removeFromParent()
        controller = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stop()
        hideOwnExit()
    }
}


/// ⚠⚠ The player's own dismiss has to close the VIEWER, not just itself.
///
/// ⚠ Static review argued this callback cannot fire for an embedded controller, and that hiding
/// our chrome therefore traps a reader on a lone clip. **Verified on device by the operator
/// (2026-08-09): exiting works.** Do not "fix" this by restoring the close button on a player
/// page without testing a single-video message on hardware first — the device is the authority
/// here and the reasoning was wrong.
///
/// Our chrome hides on a player page — the system draws its own X, and two in one corner is
/// worse than either — and the swipe-to-dismiss stands down there because a scrubber is a
/// horizontal drag inside a vertically-dismissing view. So the player's control is the only exit,
/// and if it merely collapsed its own presentation the reader would land back on a page with no
/// chrome, no swipe and nothing to swipe to. A message with one video would be a room with no
/// door.
extension MediaPlayerPageCell: AVPlayerViewControllerDelegate {
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willEndFullScreenPresentationWithAnimationCoordinator
            coordinator: UIViewControllerTransitionCoordinator
    ) {
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.onPlayerDismissed?()
        }
    }
}
