// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// The body of a message row: links are tappable, and nothing is selectable.
///
/// **Selection is something the actions sheet grants, not something the body does (#60).** Text
/// selection and the long press that opens the sheet were fighting for the same gesture, and
/// whichever won was arbitrary — so selection goes. Copy Text takes the whole line, which is what
/// you almost always wanted, and is why it's offered on every line whose text is its content
/// (including server output) rather than only on speech.
///
/// `isSelectable = false` is the only thing that actually stops selection here. Neutering the
/// `UITextInput` surface instead — reporting no `selectedTextRange`, denying `canPerformAction`,
/// refusing the loupe's gesture — is the technique every search result describes, and it does not
/// work: those posts predate TextKit 2, which tracks and draws selection through its own machinery
/// rather than through the property being overridden. Tried on device; the text still selected.
///
/// The price is that turning it off also turns off UITextView's link detection, so tapping a URL is
/// done by hand: `url(at:)` maps a point to a `.messageLink` attribute, and a tap gesture opens it. That's
/// a few lines of TextKit 2, and unlike the alternatives there's no gesture in it to fight over.
/// It's also checkable at a point rather than only by pressing the screen — see `url(at:)`.
///
/// Links are marked with `.messageLink` rather than `.link`, and styled into the attributed string
/// by `MessageRenderer` — UIKit restyles `.link` ranges with one view-wide dictionary, which can't
/// express a link that takes the color of the text around it. See the note where they're marked.
final class MessageTextView: UITextView {

    /// A link was tapped. The owner decides what opening means; nothing here reaches `UIApplication`
    /// on its own.
    var onOpenURL: ((URL) -> Void)?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isEditable = false
        isSelectable = false // the whole point; see the type's note
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let url = url(at: recognizer.location(in: self)) else { return }
        onOpenURL?(url)
    }

    /// The URL of the link under `point` (in this view's coordinates), or nil if there isn't one.
    ///
    /// Internal rather than private so it can be checked by asking it about a point whose answer is
    /// known, instead of only by tapping the screen.
    ///
    /// Two things have to be true for a hit: the point must land *inside* a laid-out line — not
    /// merely nearest to one, or the empty space beside a short line would "hit" its last character
    /// — and the character there must carry a `.messageLink` (see `MessageRenderer`, which stamps
    /// it in place of `.link`).
    func url(at point: CGPoint) -> URL? {
        guard let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let text = attributedText, text.length > 0
        else { return nil }

        // Into the text container's space: the container is inset within the view.
        let target = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        guard let fragment = layoutManager.textLayoutFragment(for: target) else { return nil }

        let inFragment = CGPoint(
            x: target.x - fragment.layoutFragmentFrame.minX,
            y: target.y - fragment.layoutFragmentFrame.minY
        )
        let fragmentStart = contentManager.offset(
            from: contentManager.documentRange.location, to: fragment.rangeInElement.location
        )
        // Each line's `typographicBounds` is positioned within the fragment (y = 0, 20, 40 for a
        // three-line paragraph), so the point picks its line directly. `characterIndex(for:)` is
        // relative to the *fragment*, not the line — a line fragment's `attributedString` is the
        // whole paragraph, not its own slice — so no per-line offset is added. Verified by probe:
        // adding one put every line after the first out of bounds and silently killed their links.
        for line in fragment.textLineFragments where line.typographicBounds.contains(inFragment) {
            let bounds = line.typographicBounds
            let inLine = CGPoint(x: inFragment.x - bounds.minX, y: inFragment.y - bounds.minY)
            let index = fragmentStart + line.characterIndex(for: inLine)
            guard index >= 0, index < text.length else { return nil }
            return text.attribute(.messageLink, at: index, effectiveRange: nil) as? URL
        }
        return nil
    }
}
