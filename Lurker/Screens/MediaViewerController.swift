// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

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
        return view
    }()

    private let counter = UILabel()
    private let closeButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private lazy var chrome = UIStackView(arrangedSubviews: [closeButton, counter, shareButton])

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

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.accessibilityLabel = "Close"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        shareButton.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        shareButton.tintColor = .white
        // ⚠ The ORIGIN address, not our proxy path. A proxy URL is authenticated and signed for
        // this session, so sharing one hands over something nobody else can open — and it leaks
        // a bearer-gated path. What a person means by "share this picture" is the address it
        // came from.
        shareButton.accessibilityLabel = "Share link"
        shareButton.addTarget(self, action: #selector(share), for: .touchUpInside)

        chrome.axis = .horizontal
        chrome.alignment = .center
        chrome.distribution = .fill
        counter.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for subview in [pages, chrome] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            pages.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pages.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pages.topAnchor.constraint(equalTo: view.topAnchor),
            pages.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            chrome.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            chrome.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            chrome.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])

        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(close))
        // ⚠ Loses to a double-tap-to-zoom, or zooming in always dismisses on the first tap of
        // the pair. The page cell owns the double tap; this waits to see if one is coming.
        dismissTap.require(toFail: doubleTapOfVisiblePage())
        pages.addGestureRecognizer(dismissTap)

        let swipe = UIPanGestureRecognizer(target: self, action: #selector(pan))
        swipe.delegate = self
        view.addGestureRecognizer(swipe)

        updateCounter()
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
        pages.addGestureRecognizer(placeholder)
        return placeholder
    }

    private func updateCounter() {
        counter.text = previews.count > 1 ? "\(index + 1) of \(previews.count)" : nil
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
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: MediaPageCell.reuseID, for: indexPath) as! MediaPageCell
        cell.configure(previews[indexPath.item], model: model)
        return cell
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pages, pages.bounds.width > 0 else { return }
        let page = Int((scrollView.contentOffset.x / pages.bounds.width).rounded())
        guard page != index, previews.indices.contains(page) else { return }
        index = page
        updateCounter()
    }
}

extension MediaViewerController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    /// ⚠ The dismiss pan stands down while the picture is zoomed in, or panning around a
    /// magnified image would throw the viewer away instead of moving the image. It also stands
    /// down for a mostly-horizontal drag, which is the reader paging between pictures.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }
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
