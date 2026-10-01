// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// A line's reactions as a row of chips under its text (iOS #183) — the web's `ReactionRow`.
///
/// One chip per value with its count: a soft fill with a faint edge, ours tinted in the accent.
/// Tapping a chip adds our reaction or takes it back; the trailing add chip — always there while
/// the line has reactions, as Slack does — opens the reaction sheet, which is also where a touch
/// screen sees who gave what (the web's hover title has no equivalent here). Square-ish on
/// purpose: round pills were tried on the web and read as "not lurker-y".
///
/// Wraps onto further lines rather than scrolling, so every chip is reachable without a gesture
/// the message list would fight over. That makes its height depend on its width, which a stack
/// view in a self-sizing cell can't discover by itself — see `availableWidth`.
final class ReactionRowView: UIView {

    /// A chip was tapped on a line we can react to: add or take back ours.
    var onToggle: ((String) -> Void)?
    /// The add chip, or a chip on a line we can't send to: open the sheet.
    var onOpen: (() -> Void)?

    /// The width the chips wrap into. Set by the cell before it's measured (and kept current by
    /// `layoutSubviews`), because the height is a function of it and Auto Layout won't ask.
    var availableWidth: CGFloat = 0 {
        didSet { if abs(oldValue - availableWidth) > 0.5 { invalidateIntrinsicContentSize() } }
    }

    private var chips: [UIButton] = []
    private let addChip = UIButton(type: .custom)
    private static let gap: CGFloat = 4
    /// The longest value a chip spells out; past it the start shows and the sheet has the whole
    /// (#1014 on the web, halloy's rule). Cut on grapheme clusters, so an emoji is never split.
    private static let maxChipCharacters = 12

    override init(frame: CGRect) {
        super.init(frame: frame)
        addChip.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .touchUpInside)
        addChip.accessibilityLabel = "Reactions"
        addChip.accessibilityHint = "Shows who reacted, and lets you add one."
        addSubview(addChip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// Draw `groups`. `canToggle` is whether a reaction can go out on this line right now — off,
    /// the chips still read normally (they're facts about the line) but a tap opens the sheet
    /// instead of sending something the server would refuse in silence. `showsAdd` is off on
    /// lines nobody can react to from here at all: a notice, an encrypted line.
    func configure(groups: [ReactionGroup], canToggle: Bool, showsAdd: Bool, traits: UITraitCollection) {
        let font = MessageRenderer.compactFont(compatibleWith: traits)
        for chip in chips { chip.removeFromSuperview() }
        chips = groups.map { group in
            let chip = UIButton(type: .custom)
            chip.configuration = Self.chipConfiguration(group: group, font: font, traits: traits)
            let value = group.value
            chip.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if canToggle { onToggle?(value) } else { onOpen?() }
            }, for: .touchUpInside)
            chip.accessibilityLabel = Self.spoken(group)
            chip.accessibilityTraits = group.mine ? [.button, .selected] : .button
            chip.accessibilityHint = canToggle
                ? (group.mine ? "Takes your reaction back." : "Adds your reaction.")
                : nil
            addSubview(chip)
            return chip
        }
        addChip.isHidden = !showsAdd
        addChip.configuration = Self.addConfiguration(font: font, traits: traits)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// Whether `point` (in this view's space) lands on a chip — so the list's long press can
    /// open the sheet there rather than the line's actions.
    func containsChip(at point: CGPoint) -> Bool {
        (chips + [addChip]).contains { !$0.isHidden && $0.frame.insetBy(dx: -2, dy: -2).contains(point) }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: frames(in: availableWidth).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A width the cell didn't predict (it measured before it knew its safe area, say): wrap to
        // the real one, and say so if that changes the height.
        if bounds.width > 0 { availableWidth = bounds.width }
        let laid = frames(in: bounds.width)
        for (view, frame) in zip(visibleViews, laid.frames) { view.frame = frame }
    }

    private var visibleViews: [UIView] { addChip.isHidden ? chips : chips + [addChip] }

    /// Left-to-right, wrapping when the next chip won't fit. A chip wider than the whole row (a
    /// long text value at a huge type size) gets a line to itself and is narrowed to fit it.
    private func frames(in width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        guard width > 0 else { return ([], 0) }
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for view in visibleViews {
            var size = view.intrinsicContentSize
            size.width = min(ceil(size.width), width)
            size.height = ceil(size.height)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + Self.gap
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + Self.gap
            lineHeight = max(lineHeight, size.height)
        }
        return (frames, frames.isEmpty ? 0 : y + lineHeight)
    }

    // MARK: - Look

    private static func chipConfiguration(group: ReactionGroup, font: UIFont, traits: UITraitCollection) -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        let ink = group.mine ? Palette.accent : Palette.fgMuted
        let title = NSMutableAttributedString(
            string: clipped(group.value),
            attributes: [.font: font, .foregroundColor: ink.resolvedColor(with: traits)]
        )
        title.append(NSAttributedString(
            string: " \(group.nicks.count)",
            attributes: [.font: font, .foregroundColor: ink.resolvedColor(with: traits)]
        ))
        config.attributedTitle = AttributedString(title)
        config.titleLineBreakMode = .byTruncatingTail
        // A pixel more below than above: an emoji's glyph sits low in the line, and even padding
        // left it touching the bottom edge while its top floated (the web's correction too).
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 6, bottom: 3, trailing: 6)
        config.background.cornerRadius = 4
        config.background.strokeWidth = 1
        config.background.backgroundColor = (group.mine
            ? Palette.translucent(Palette.accent, alpha: 0.15) : Palette.bgSoft).resolvedColor(with: traits)
        config.background.strokeColor = (group.mine
            ? Palette.translucent(Palette.accent, alpha: 0.3) : Palette.border).resolvedColor(with: traits)
        return config
    }

    /// The add chip: a placeholder, not a reaction, so it's faded well below the chips beside it
    /// — the web found a placeholder-strength glyph still read as one more reaction.
    private static func addConfiguration(font: UIFont, traits: UITraitCollection) -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        // Tinted by the button rather than baked into the image: a baked tint drew this symbol as
        // a filled disc in dark mode.
        config.image = UIImage(
            systemName: "face.smiling",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: font.pointSize * 0.95, weight: .light)
                .applying(UIImage.SymbolConfiguration.preferringMonochrome())
        )?.withRenderingMode(.alwaysTemplate)
        config.baseForegroundColor = Palette.translucent(Palette.fgMuted, alpha: 0.55).resolvedColor(with: traits)
        // The same box as a chip, so a row of them lines up: the image is a line of text tall.
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 2 + max(0, (font.lineHeight - font.pointSize) / 2), leading: 6,
            bottom: 3 + max(0, (font.lineHeight - font.pointSize) / 2), trailing: 6
        )
        config.background.cornerRadius = 4
        config.background.strokeWidth = 1
        config.background.backgroundColor = .clear
        config.background.strokeColor = Palette.translucent(Palette.border, alpha: 0.6).resolvedColor(with: traits)
        return config
    }

    private static func clipped(_ value: String) -> String {
        value.count > maxChipCharacters ? String(value.prefix(maxChipCharacters - 1)) + "…" : value
    }

    /// "thumbs up, 2: alice, bob" — VoiceOver names the emoji itself.
    private static func spoken(_ group: ReactionGroup) -> String {
        "\(group.value), \(group.nicks.count): \(group.nicks.joined(separator: ", "))"
    }
}
