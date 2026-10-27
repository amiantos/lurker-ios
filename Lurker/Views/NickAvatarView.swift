// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The tile beside an author in the compact layout (lurker#607, Mobile lurker#1203) — the web's
/// `NickAvatar.vue`.
///
/// A square in the nick's colour. On it, in this order of preference: the picture the user set
/// through IRCv3 metadata, as the server minted it; else one image from the active tile set,
/// picked by `AvatarTiles.index` so every client draws the same one; else, for an Initial set,
/// the first letter of the shown name. A notice's head and a server line's head get a glyph over
/// the colour instead of a face — a megaphone, a rack — as the web gives them.
///
/// Images come through `PreviewImageLoader`: a metadata avatar is a proxied fetch with the bearer
/// token, a set tile a static file, and both are cached and decoded the way preview pictures are.
/// A metadata image that fails is latched by the loader and never arrives, so the tile beneath it
/// simply stays — the web's `@error` fallback without a second code path.
final class NickAvatarView: UIView {
    /// The placeholder glyph for a head that isn't a person's.
    enum Mark: Equatable {
        /// `-nick-`: a notice, the bot talking at the room.
        case notice
        /// The server itself, or the app: a system line, raw server text.
        case server
    }

    /// Everything one tile needs, resolved by `spec(for:…)` from the store and handed to the cell.
    struct Spec: Equatable {
        /// What the tile stands for — for VoiceOver, and the hash behind `tilePath`.
        let nick: String?
        let color: UIColor
        /// The metadata avatar's server-minted path, or nil for the generated tile.
        let imagePath: String?
        /// The active set's tile for this nick, or nil for an Initial set or an unread manifest.
        let tilePath: String?
        /// The letter an Initial set draws, upper-cased.
        let letter: String?
        let ink: AvatarInk
        let mark: Mark?
    }

    /// A tap on a person's tile. Nil on a placeholder (a notice, the server), where the tile is
    /// decoration and a tap falls through to the row — as the web lets it.
    var onTap: (() -> Void)? {
        didSet {
            isAccessibilityElement = onTap != nil
            accessibilityTraits = onTap == nil ? .image : .button
        }
    }

    private let imageView = UIImageView()
    private let letterLabel = UILabel()
    private let markView = UIImageView()
    /// Bumped per configure, so an image that lands for the row this cell USED to show is dropped.
    private var generation = 0
    /// Which layer the picture on screen came from: the tile (0) or the metadata avatar (1), so a
    /// slow tile can't paint over the avatar that already landed.
    private var shownLayer = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        imageView.contentMode = .scaleAspectFill
        imageView.translatesAutoresizingMaskIntoConstraints = false
        letterLabel.textAlignment = .center
        letterLabel.adjustsFontSizeToFitWidth = true
        letterLabel.translatesAutoresizingMaskIntoConstraints = false
        markView.contentMode = .center
        markView.translatesAutoresizingMaskIntoConstraints = false
        for view in [imageView, letterLabel, markView] as [UIView] {
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    @objc private func tapped() { onTap?() }

    /// Draw `spec` at `size` points. `model` fetches the pictures; nil draws colour and letter only
    /// (the layout probes have no model).
    func configure(_ spec: Spec, size: CGFloat, model: ChatViewModel?) {
        generation += 1
        let generation = generation
        shownLayer = -1
        backgroundColor = spec.color
        let ink = Self.ink(spec.ink)
        // Half the tile, 600 weight, as the web's `.initial` has it.
        letterLabel.font = .systemFont(ofSize: size * 0.5, weight: .semibold)
        letterLabel.textColor = ink
        letterLabel.text = spec.letter
        letterLabel.isHidden = spec.letter == nil
        markView.tintColor = ink
        markView.image = spec.mark.map { mark in
            UIImage(
                systemName: mark == .notice ? "megaphone.fill" : "server.rack",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.45, weight: .semibold)
            ) ?? UIImage()
        }
        markView.isHidden = spec.mark == nil
        imageView.image = nil
        imageView.isHidden = true
        accessibilityLabel = spec.nick
        guard let model else { return }
        // An avatar already decoded is the whole answer: no tile fetched underneath it to be
        // thrown away. Otherwise the tile first and the avatar over it, so whichever is cached
        // shows at once and the avatar replaces the tile when it lands rather than leaving a blank
        // square while it loads.
        if let image = spec.imagePath, let cached = PreviewImageLoader.shared.image(for: image) {
            place(cached, layer: 1)
            return
        }
        if let tile = spec.tilePath { show(tile, layer: 0, model: model, generation: generation) }
        if let image = spec.imagePath { show(image, layer: 1, model: model, generation: generation) }
    }

    private func show(_ path: String, layer: Int, model: ChatViewModel, generation: Int) {
        if let cached = PreviewImageLoader.shared.image(for: path) {
            place(cached, layer: layer)
            return
        }
        PreviewImageLoader.shared.load(path: path, using: model) { [weak self] image in
            guard let self, self.generation == generation else { return }
            place(image, layer: layer)
        }
    }

    private func place(_ image: UIImage, layer: Int) {
        guard layer >= shownLayer else { return }
        shownLayer = layer
        imageView.image = image
        imageView.isHidden = false
        // A picture covers the letter; the colour stays underneath a tile with alpha.
        letterLabel.isHidden = true
    }

    /// The web's two inks: `rgba(255,255,255,0.85)` and `rgba(28,26,30,0.85)`.
    private static func ink(_ ink: AvatarInk) -> UIColor {
        switch ink {
        case .light: UIColor(white: 1, alpha: 0.85)
        case .dark: UIColor(red: 28 / 255, green: 26 / 255, blue: 30 / 255, alpha: 0.85)
        }
    }

    // MARK: - Geometry

    /// The tile's side: the web's `min(2.25em, 2lh)` at phone width and `min(2.7em, 2lh)` wider,
    /// in the compact face's points — so a tight line height (lurker#1186) shrinks the tile rather
    /// than letting it outgrow the head and first body line it is centred on. Whole points, so the
    /// hairline beside it lands on the pixel grid.
    static func size(spacing: MessageRenderer.CompactSpacing, traits: UITraitCollection) -> CGFloat {
        let font = MessageRenderer.compactFont(compatibleWith: traits)
        let em: CGFloat = traits.horizontalSizeClass == .regular ? 2.7 : 2.25
        let twoLines = 2 * (font.lineHeight + spacing.lineGap)
        return floor(min(em * font.pointSize, twoLines))
    }

    /// The web's `--space-4` between the tile and the hairline, and `--space-5` after it. The tile
    /// itself sits at the row's side margin, where the text sits without the column.
    static let gutterPadding: CGFloat = 8
    static let gutterAfterLine: CGFloat = 10

    // MARK: - Resolution

    /// What `message`'s head draws (the web's `NickAvatar` props, resolved).
    ///
    /// A re-attributed relay line (`relayBot != nil`) gets no metadata — not the avatar, not the
    /// display name's initial: the bridged speaker isn't a network nick, and a record under that
    /// spelling would be someone else's. Its generated tile still hashes the shown name, as the
    /// web's does.
    ///
    /// `active` and `stopChars` are resolved once per list by the caller (`AvatarSets.active`,
    /// `AvatarSets.stopChars`), not per row: the resolution walks every set.
    static func spec(
        for message: Message, networkId: Int?, state: ChatState,
        active: AvatarSet, stopChars: Set<Unicode.Scalar>, networkName: String?
    ) -> Spec {
        let nick: String?
        let color: UIColor
        let mark: Mark?
        switch message.type {
        case .notice:
            nick = message.nick
            color = MessageRenderer.nickColor(message)
            mark = .notice
        case .system, .motd, .other:
            nick = networkName
            color = MessageRenderer.captionColor(message, networkName: networkName)
            mark = .server
        default:
            nick = message.nick
            color = MessageRenderer.nickColor(message)
            mark = nil
        }
        let relayed = message.relayBot != nil
        let meta = relayed || mark != nil ? nil : state.metadata(networkId: networkId, nick: nick)
        var letter: String?
        if mark == nil, case .initial = active.kind {
            let shown = relayed ? nil : state.plainDisplayName(networkId: networkId, nick: nick)
            // The first code point, as the web's `Array.from(name)[0]`, upper-cased.
            letter = (shown ?? nick)?.unicodeScalars.first.map { String($0).uppercased() }
        }
        return Spec(
            nick: nick,
            color: color,
            imagePath: meta?.avatarUrl,
            tilePath: mark == nil ? active.tilePath(for: nick, stopChars: stopChars) : nil,
            letter: letter,
            ink: active.ink,
            mark: mark
        )
    }
}
