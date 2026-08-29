// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// One upload in the browser's grid (#138): a square of artwork, the filename under it, and a
/// line of when and how big.
///
/// A grid rather than a list because the case that needs a browser is "that screenshot from
/// March", and the eye scans pictures far faster than it reads filenames. Files with no
/// thumbnail — audio, text, and any video whose instance couldn't decode a poster — get a
/// type glyph in the same square rather than a different layout: a card that happens to show an
/// icon reads as a peer of one that shows a photo, where a separate list of them would not.
final class UploadTileCell: UICollectionViewCell {
    static let reuseID = "UploadTile"

    private let art = UIImageView()
    private let glyph = UIImageView()
    private let star = UIImageView()
    private let name = UILabel()
    private let meta = UILabel()

    /// The thumbnail path this cell is currently drawing, so a load that lands after the cell
    /// has been recycled can be dropped rather than painting the wrong tile.
    private var thumbnailPath: String?

    override init(frame: CGRect) {
        super.init(frame: frame)

        art.contentMode = .scaleAspectFill
        art.clipsToBounds = true
        art.layer.cornerRadius = 10
        art.layer.cornerCurve = .continuous
        // A neutral bed under both cases: it is what a tile looks like before its thumbnail
        // lands, and what a glyph tile looks like forever.
        art.backgroundColor = .secondarySystemFill
        art.isAccessibilityElement = false

        glyph.contentMode = .scaleAspectFit
        glyph.tintColor = .secondaryLabel
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 28, weight: .regular)
        glyph.isAccessibilityElement = false

        // ⚠ The star is a STATE badge as much as a control, so it stays visible once set rather
        // than living only in the context menu that sets it: the starred set is meant to be
        // recognisable while scanning the unfiltered grid, which is the whole point of having
        // one. It is not itself tappable — a 16pt target inside a tile that is already a button
        // would be a coin toss between "open this" and "unstar this".
        star.image = UIImage(systemName: "star.fill")
        star.tintColor = .systemYellow
        star.contentMode = .scaleAspectFit
        star.isHidden = true
        star.isAccessibilityElement = false
        // Its own scrim, for the same reason the media viewer's buttons carry one: a yellow
        // glyph over an unknown picture can land on anything.
        star.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        star.layer.cornerRadius = 9
        star.layer.masksToBounds = true

        name.font = .preferredFont(forTextStyle: .footnote)
        name.adjustsFontForContentSizeCategory = true
        name.textColor = .label
        name.lineBreakMode = .byTruncatingMiddle
        // ⚠ Truncated in the MIDDLE, not the tail. Uploaded filenames share long prefixes
        // (`IMG_4821`, `Screenshot 2026-08-…`) and differ in the part a tail truncation eats
        // first, so a column of tail-truncated names is a column of identical strings.
        name.isAccessibilityElement = false

        meta.font = .preferredFont(forTextStyle: .caption2)
        meta.adjustsFontForContentSizeCategory = true
        meta.textColor = .secondaryLabel
        meta.isAccessibilityElement = false

        let text = UIStackView(arrangedSubviews: [name, meta])
        text.axis = .vertical
        text.spacing = 1

        for subview in [art, glyph, star, text] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo: contentView.topAnchor),
            art.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            art.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            art.heightAnchor.constraint(equalTo: art.widthAnchor),

            glyph.centerXAnchor.constraint(equalTo: art.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: art.centerYAnchor),

            star.trailingAnchor.constraint(equalTo: art.trailingAnchor, constant: -5),
            star.topAnchor.constraint(equalTo: art.topAnchor, constant: 5),
            star.widthAnchor.constraint(equalToConstant: 18),
            star.heightAnchor.constraint(equalToConstant: 18),

            text.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 5),
            text.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            // Less-than, not equal: the labels grow with Dynamic Type and the group is
            // `.estimated`, so the cell takes whatever height they end up needing.
            text.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func prepareForReuse() {
        super.prepareForReuse()
        art.image = nil
        thumbnailPath = nil
        art.alpha = 1
    }

    func configure(_ item: UploadItem, model: ChatViewModel) {
        name.text = item.displayName
        meta.text = Self.metaLine(item)
        star.isHidden = !item.favorite
        // A tombstone is dimmed rather than hidden: the row is still a true record of something
        // you uploaded, and a grid that silently skipped them would make files vanish with no
        // account of where they went.
        art.alpha = item.removed ? 0.5 : 1

        glyph.image = UIImage(systemName: Self.symbol(for: item))
        thumbnailPath = item.thumbnailPath
        guard let path = item.thumbnailPath else {
            glyph.isHidden = false
            accessibilityLabel = Self.accessibilityLabel(item)
            return
        }
        // Show the glyph while the picture is on its way; it is replaced on arrival, and stays
        // if the fetch fails.
        glyph.isHidden = false
        art.image = PreviewImageLoader.shared.image(for: path)
        if art.image != nil { glyph.isHidden = true }
        PreviewImageLoader.shared.load(path: path, using: model) { [weak self] image in
            // ⚠ The path check, not just `[weak self]`: a cell is alive and REUSED, so a load
            // that lands late would otherwise paint one upload's thumbnail onto another's tile.
            guard let self, thumbnailPath == path else { return }
            art.image = image
            glyph.isHidden = true
        }
        accessibilityLabel = Self.accessibilityLabel(item)
    }

    /// When and how big, in that order — the two things that identify a file you are trying to
    /// find again.
    ///
    /// Deliberately does NOT name the uploader. Which backend a file happened to land on is the
    /// app's business, not the reader's: it doesn't help recognise a picture and isn't actionable
    /// from here. When it matters — the file is gone, or can't be deleted — that surfaces as its
    /// own state rather than as a label on every tile.
    private static func metaLine(_ item: UploadItem) -> String {
        if item.removed { return "Removed" }
        var parts: [String] = []
        if let created = item.createdAt {
            parts.append(relative.localizedString(for: created, relativeTo: Date()))
        }
        if let bytes = item.byteSize { parts.append(formatBytes(bytes)) }
        return parts.joined(separator: " · ")
    }

    private static func symbol(for item: UploadItem) -> String {
        // No gavel in SF Symbols, and the "hammer" that comes closest reads as *build*. A
        // prohibition sign is what a person recognises as "taken down", and the caption says the
        // word anyway.
        if item.removed { return "nosign" }
        switch item.kind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .text: return "doc.text"
        case nil: return "doc"
        }
    }

    private static func accessibilityLabel(_ item: UploadItem) -> String {
        [item.displayName, item.favorite ? "starred" : nil, metaLine(item)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        // ⚠ `.named`, so something uploaded moments ago says "now" rather than "in 0s". The
        // numeric style has no word for the present and rounds a sub-second gap to whichever side
        // of zero the clock happens to land on — measured, in a render of a just-created row.
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private static func formatBytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
