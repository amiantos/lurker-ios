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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        (pages.collectionViewLayout as? UICollectionViewFlowLayout)?.itemSize = pages.bounds.size
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
    /// So on a player page ours gets out of the way rather than trying to coexist: the counter
    /// and share step aside and the player's chrome is the interface, which is the one people
    /// already know how to use. The close button STAYS — it is top-left, clear of everything the
    /// player draws, and it is the only way out of a video page since the swipe stands down
    /// there too (its scrubber is a horizontal drag inside a vertically-dismissing view).
    ///
    /// ⚠ The cost is that a video can't be shared from in here. The address is still in the
    /// message, and losing a button beats losing the player's own controls.
    private func updateChrome() {
        let isPlayer = previews.indices.contains(index) && previews[index].kind != .image
        counter.text = previews.count > 1 ? "\(index + 1) of \(previews.count)" : nil
        counter.isHidden = isPlayer
        shareButton.isHidden = isPlayer
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
        cell.configure(preview, model: model, host: self) { [weak self] url in
            self?.dismiss(animated: true) { UIApplication.shared.open(url) }
        }
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
    private let spinner = UIActivityIndicatorView(style: .large)
    private let fallback = UIStackView()
    private let fallbackLabel = UILabel()
    private let fallbackButton = UIButton(type: .system)
    private var openExternally: ((URL) -> Void)?
    private var originURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)

        fallbackLabel.textColor = .white
        fallbackLabel.textAlignment = .center
        fallbackLabel.numberOfLines = 0
        fallbackLabel.font = .preferredFont(forTextStyle: .callout)
        fallbackLabel.adjustsFontForContentSizeCategory = true
        fallbackButton.setTitle("Open in Browser", for: .normal)
        fallbackButton.addTarget(self, action: #selector(openOutside), for: .touchUpInside)
        fallback.axis = .vertical
        fallback.spacing = 12
        fallback.alignment = .center
        fallback.isHidden = true
        fallback.addArrangedSubview(fallbackLabel)
        fallback.addArrangedSubview(fallbackButton)
        fallback.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(fallback)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
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
        openExternally: @escaping (URL) -> Void
    ) {
        path = preview.src
        self.openExternally = openExternally
        originURL = URL(string: preview.url)
        fallback.isHidden = true
        guard let source = preview.src else {
            showFallback("There's nothing to play here.")
            return
        }
        spinner.startAnimating()

        Task { @MainActor in
            // ⚠ A proxy path is downloaded before it can play — the bytes are bearer-gated and
            // AVURLAsset cannot carry the header. Bounded by the proxy's own 8 MB cap, which is
            // what makes waiting rather than streaming survivable.
            guard let url = await model.playableMediaURL(path: source, mime: preview.mime),
                self.path == source
            else {
                self.spinner.stopAnimating()
                self.showFallback("This couldn't be loaded.")
                return
            }
            let asset = AVURLAsset(url: url)
            // ⚠ ASKED, not assumed. The server proxies any `video/*`, and this platform decodes
            // neither webm nor ogg — both common enough on IRC to matter. A player that spins
            // forever is a worse answer than a sentence and a button.
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard self.path == source else { return }
            self.spinner.stopAnimating()
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
        controller.videoGravity = .resizeAspect
        // Audio has no picture, so the player draws its own placeholder rather than a black void.
        controller.view.backgroundColor = .clear
        host.addChild(controller)
        controller.view.frame = contentView.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(controller.view)
        controller.didMove(toParent: host)
        self.controller = controller
        player.play()
    }

    private func showFallback(_ message: String) {
        fallbackLabel.text = message
        fallback.isHidden = false
        fallbackButton.isHidden = originURL == nil
    }

    @objc private func openOutside() {
        guard let originURL else { return }
        openExternally?(originURL)
    }

    /// Stop and tear down. Called when the page scrolls away and when the viewer closes.
    func stop() {
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
        path = nil
        spinner.stopAnimating()
        fallback.isHidden = true
    }
}
