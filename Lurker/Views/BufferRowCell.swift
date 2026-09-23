// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The buffer list's three kinds of cell: a buffer's row, a group's header, and the dashed
/// break between a network's pinned buffers and the rest.
///
/// The list is a tree, drawn the way the web sidebar draws it: an uppercase header per group
/// and a `├─`/`└─` guide beside every row under it, in the log's monospaced face, on the
/// message list's own ground. No cards: the guides say which rows belong together, which is
/// the job the inset-grouped cards and the chip grids did before at several times the height.

/// Where a row sits under its header: `├─` when more rows follow it, `└─` for the last.
enum TreeGuide: Equatable {
    case tee
    case elbow
}

/// One set of measurements for every cell, so a header's text, the tree's spine and a row's
/// name line up by construction rather than by matching constants in three places.
///
/// Everything horizontal is measured from the **safe area**, not the layout margins. The iPhone
/// Duo's 84pt side rail swallows a layout margin rather than adding to it (measured, iOS 27.1:
/// a cell's trailing margin went to 0), which would put a count flush against the rail.
enum RosterMetrics {
    /// Safe-area edge to a header's text, and a count to the trailing edge.
    static let inset: CGFloat = 20
    /// `inset` to the tree's vertical line.
    static let spine: CGFloat = 6
    /// `inset` to a row's name: past the spine and its arm, with a gap after the arm.
    static let name: CGFloat = 24
    /// The arm's length: the `─` of `├─`.
    static let arm: CGFloat = 9
    /// A row's floor. Under the 44pt guideline — a deliberate trade for a list you scan, and the
    /// whole width of the row is the target. It grows with Dynamic Type.
    static let row: CGFloat = 32
    static let header: CGFloat = 30
    /// The space between a group's last row and the rule over the next group, and between that
    /// rule and the next header.
    static let groupGap: CGFloat = 6
    /// The open row's accent edge.
    static let edge: CGFloat = 2
    static let pinBreak: CGFloat = 10
}

extension UIColor {
    /// What a roster cell stands on.
    ///
    /// Collapsed, the list paints `Palette.bg` and so does every cell — opaque, because a row
    /// sliding over its swipe actions shows whatever is behind it. Side by side, UIKit clears the
    /// sidebar's layer and draws its glass there (measured on iOS 27.1), and an opaque cell would
    /// print a strip of `Palette.bg` across it, so there the cells are clear.
    static var rosterGround: UIColor {
        UIColor { traits in
            traits.splitViewControllerLayoutEnvironment == .expanded
                ? .clear : Palette.bg.resolvedColor(with: traits)
        }
    }

    /// A pressed row, and the open one: the web's `bg_soft`. Over the sidebar's glass the same
    /// step is a translucent wash of the foreground, because `bg_soft` is darker than dark glass
    /// and would read as a hole rather than a lift.
    static var rosterRaised: UIColor {
        UIColor { traits in
            traits.splitViewControllerLayoutEnvironment == .expanded
                ? Palette.fg.resolvedColor(with: traits).withAlphaComponent(0.07)
                : Palette.bgSoft.resolvedColor(with: traits)
        }
    }

    /// The tree guides and the rule between groups. Derived from `fgMuted` rather than the web's
    /// `border`, which disappears on the sidebar's glass; a wash of the muted text reads on the
    /// message list's ground and on glass alike.
    static let rosterGuide = Palette.translucent(Palette.fgMuted, alpha: 0.4)
}

// MARK: - Guide

/// The `├─` or `└─` beside a row, or the bare `│` through the pinned break.
///
/// Built from plain views rather than drawn, so the guide colour follows the appearance
/// without a trait handler: a view's dynamic `backgroundColor` re-resolves on its own.
final class TreeGuideView: UIView {
    enum Shape: Equatable {
        case tee
        case elbow
        /// The spine alone, for the pinned break.
        case spine
    }

    var shape: Shape = .tee {
        didSet { if shape != oldValue { setNeedsLayout() } }
    }

    private let stem = UIView()
    private let arm = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for line in [stem, arm] {
            line.backgroundColor = .rosterGuide
            addSubview(line)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let middle = (bounds.height / 2).rounded()
        stem.frame = CGRect(x: 0, y: 0, width: 1, height: shape == .elbow ? middle + 1 : bounds.height)
        arm.isHidden = shape == .spine
        arm.frame = CGRect(x: 0, y: middle, width: RosterMetrics.arm, height: 1)
    }
}

// MARK: - Row

/// One buffer: its name, an optional network hint, and its unread count, beside a tree guide.
///
/// Unread is colour, the web's rule: the name turns the accent and the count is plain text in
/// the same colour; a highlight makes both `bad`. There is no pill — a capsule is a card in
/// miniature, and this list has none.
final class BufferRowCell: UICollectionViewListCell {
    private let guide = TreeGuideView()
    private let nameLabel = UILabel()
    private let hintLabel = UILabel()
    private let countLabel = UILabel()
    /// The pressed and open fill. A view rather than the background configuration, which is
    /// left holding the ground alone — see `updateConfiguration`.
    private let band = UIView()
    private let edge = UIView()
    private var isOpen = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        band.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(band)

        edge.backgroundColor = Palette.accent
        edge.isHidden = true
        edge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(edge)

        guide.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(guide)

        nameLabel.lineBreakMode = .byTruncatingTail
        // The hint holds and the NAME truncates: two long names that collide are exactly the
        // pair the hint exists to tell apart, and a tail ellipsis would eat it first. 999, not
        // required, so a hint that falls back to a whole network name still loses to the edge.
        hintLabel.textColor = Palette.fgMuted
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)
        hintLabel.setContentCompressionResistancePriority(.init(999), for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Text never gives up height to the row's preferred 32pt — at their default 750 the
        // labels tied with it, and at accessibility sizes the row clipped every descender.
        for label in [nameLabel, hintLabel, countLabel] {
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        // A spacer takes the slack, or the name stretches and strands the hint at the far edge.
        let spacer = UIView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let text = UIStackView(arrangedSubviews: [nameLabel, hintLabel, spacer, countLabel])
        text.axis = .horizontal
        text.spacing = 10
        text.setCustomSpacing(8, after: nameLabel)
        text.alignment = .center
        text.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(text)

        let safe = contentView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: contentView.topAnchor),
            band.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            band.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            edge.topAnchor.constraint(equalTo: contentView.topAnchor),
            edge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            edge.widthAnchor.constraint(equalToConstant: RosterMetrics.edge),

            // Top to bottom, so one row's stem meets the next row's with no gap between cells.
            guide.topAnchor.constraint(equalTo: contentView.topAnchor),
            guide.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            guide.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: RosterMetrics.inset + RosterMetrics.spine),
            guide.widthAnchor.constraint(equalToConstant: RosterMetrics.arm),

            text.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: RosterMetrics.inset + RosterMetrics.name),
            text.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -RosterMetrics.inset),
            text.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 7),
            text.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -7),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: RosterMetrics.row),
            // ⚠ A preferred height, not just floors. With only `>=` constraints the list sized
            // these rows to ~52pt (measured, iOS 27 simulator) — something in the list cell's
            // own sizing outranks the fitting priority, and floors don't argue with it.
            Self.preferred(contentView.heightAnchor.constraint(equalToConstant: RosterMetrics.row)),
        ])

        // One element: VoiceOver reads "#general, libera, 3 unread" and activates the row,
        // rather than landing on the name, the hint and the count one at a time.
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// A height the cell should take unless its text needs more: below required, so a larger
    /// Dynamic Type size wins over it, and above the fitting level, so it isn't negotiable
    /// otherwise.
    static func preferred(_ constraint: NSLayoutConstraint) -> NSLayoutConstraint {
        constraint.priority = .defaultHigh
        return constraint
    }

    /// `font` comes from the list, built from its own traits: a cell's traits aren't settled
    /// while it's configured, and an offline peer's italic has to be a font rather than a colour.
    ///
    /// `networkName` is the full name, for the accessibility label only; the hint is its short
    /// visual stand-in and is set only where two rows would otherwise read alike.
    func configure(
        name: String,
        font: UIFont,
        hintFont: UIFont,
        networkName: String?,
        networkHint: String?,
        unread: Int,
        highlights: Int,
        presence: FriendPresence?,
        parted: Bool,
        isOpen: Bool,
        guide shape: TreeGuide
    ) {
        self.isOpen = isOpen
        edge.isHidden = !isOpen
        guide.shape = shape == .tee ? .tee : .elbow

        let signal: UIColor? = highlights > 0 && unread > 0 ? Palette.bad : (unread > 0 ? Palette.accent : nil)
        nameLabel.text = name
        nameLabel.font = font
        // Away or offline mutes the name even with something waiting, as the web's `peer-away`
        // outranks its `unread`; the count keeps its colour, so what's waiting still shows.
        nameLabel.textColor = presence?.dimsName == true ? Palette.fgMuted : (signal ?? Palette.fg)
        hintLabel.text = networkHint
        hintLabel.font = hintFont
        hintLabel.isHidden = networkHint == nil
        countLabel.text = unread > 0 ? "\(unread)" : nil
        countLabel.font = hintFont
        countLabel.textColor = signal ?? Palette.accent
        countLabel.isHidden = unread == 0

        // A channel we're not in: the row's text at half strength. Not the guide, unlike the
        // web's whole-row opacity — a dimmed piece of spine reads as a break in the tree.
        let alpha: CGFloat = parted ? 0.5 : 1
        for label in [nameLabel, hintLabel, countLabel] { label.alpha = alpha }

        var summary = networkName.map { "\(name), \($0)" } ?? name
        if parted { summary += ", not joined" }
        if let presence, presence.dimsName { summary += ", \(presence.accessibilityLabel)" }
        if unread > 0 { summary += highlights > 0 ? ", \(unread) unread, mentioned" : ", \(unread) unread" }
        accessibilityLabel = summary
        setNeedsUpdateConfiguration()
    }

    /// The ground is named every time and nothing else is left to the list cell's defaults,
    /// whose highlight would paint the system grey over the theme. The press shows on `band`.
    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = .rosterGround
        backgroundConfiguration = background
        band.backgroundColor = isOpen || state.isHighlighted || state.isSelected ? .rosterRaised : .clear
    }

    /// A row lifted for reordering: the raised fill, so the text doesn't float on nothing over
    /// the sidebar's glass.
    var dragPreviewParameters: UIDragPreviewParameters {
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(rect: bounds)
        parameters.backgroundColor = Palette.bgSoft
        return parameters
    }
}

// MARK: - Header

/// A group's header: FRIENDS, FAVORITES, or a network.
///
/// A network's header is also its server log, the web sidebar's shape — tapping it opens the
/// log, and it carries the log's unread count and the open mark when that's the conversation
/// beside the list. It shows the network's state as a dot, and in words when it isn't connected.
///
/// Every header after the first draws the rule that separates it from the group above.
final class RosterHeaderCell: UICollectionViewListCell {
    private let rule = UIView()
    private let row = UIView()
    private let band = UIView()
    private let edge = UIView()
    private let dot = UIView()
    private let titleLabel = UILabel()
    private let stateLabel = UILabel()
    private let countLabel = UILabel()
    private var rowTop: NSLayoutConstraint!
    private var isOpen = false
    private var opensLog = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        rule.backgroundColor = .rosterGuide
        row.translatesAutoresizingMaskIntoConstraints = false
        for view in [rule, row] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        band.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(band)
        edge.backgroundColor = Palette.accent
        edge.isHidden = true
        edge.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(edge)

        dot.layer.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.textColor = Palette.fgMuted
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [stateLabel, countLabel] {
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        // See the row's labels: text keeps its height over the header's preferred 30pt.
        for label in [titleLabel, stateLabel, countLabel] {
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        let spacer = UIView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [dot, titleLabel, spacer, stateLabel, countLabel])
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)

        let safe = contentView.safeAreaLayoutGuide
        rowTop = row.topAnchor.constraint(equalTo: contentView.topAnchor)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: contentView.topAnchor),
            rule.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),

            rowTop,
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: RosterMetrics.header),

            band.topAnchor.constraint(equalTo: row.topAnchor),
            band.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            band.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            edge.topAnchor.constraint(equalTo: row.topAnchor),
            edge.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            edge.widthAnchor.constraint(equalToConstant: RosterMetrics.edge),

            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            stack.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: RosterMetrics.inset),
            stack.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -RosterMetrics.inset),
            stack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -6),
            // See the row's matching constraint.
            BufferRowCell.preferred(row.heightAnchor.constraint(equalToConstant: RosterMetrics.header)),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// `light` is the network's state as a dot, nil for FRIENDS and FAVORITES; `state` the same
    /// in words, set only when it isn't connected. `unread` is the server log's, and only a
    /// header that `opensLog` has one.
    func configure(
        title: String,
        font: UIFont,
        light: StatusLight?,
        state: String?,
        unread: Int,
        highlights: Int,
        ruleAbove: Bool,
        opensLog: Bool,
        isOpen: Bool
    ) {
        self.isOpen = isOpen
        self.opensLog = opensLog
        rule.isHidden = !ruleAbove
        rowTop.constant = ruleAbove ? 1 + RosterMetrics.groupGap : 0
        edge.isHidden = !isOpen

        // Uppercase and tracked, at the one font size: the web's `.net-head`, which demotes
        // itself with colour and case rather than a smaller face.
        titleLabel.attributedText = NSAttributedString(string: title.uppercased(), attributes: [
            .font: font,
            .foregroundColor: Palette.fgMuted,
            .kern: font.pointSize * 0.04,
        ])
        dot.isHidden = light == nil
        dot.backgroundColor = light.map { Palette.color(for: $0) }
        stateLabel.text = state
        stateLabel.font = font
        stateLabel.isHidden = state == nil
        countLabel.text = unread > 0 ? "\(unread)" : nil
        countLabel.font = font
        countLabel.textColor = highlights > 0 ? Palette.bad : Palette.accent
        countLabel.isHidden = unread == 0

        var summary = title
        if let state { summary += ", \(state)" }
        if unread > 0 { summary += highlights > 0 ? ", \(unread) unread, mentioned" : ", \(unread) unread" }
        accessibilityLabel = summary
        accessibilityTraits = opensLog ? [.header, .button] : .header
        accessibilityHint = opensLog ? "Opens the server log" : nil
        setNeedsUpdateConfiguration()
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = .rosterGround
        backgroundConfiguration = background
        let pressed = opensLog && (state.isHighlighted || state.isSelected)
        band.backgroundColor = isOpen || pressed ? .rosterRaised : .clear
    }
}

// MARK: - Pinned break

/// The break between a network's pinned buffers and the rest: the spine carried through, and a
/// dashed rule across. The web's `.pin-divider` — a phantom row that says "section break"
/// without spending a header on it.
final class PinBreakCell: UICollectionViewListCell {
    private let spine = TreeGuideView()
    private let dashes = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        spine.shape = .spine
        spine.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spine)
        dashes.lineWidth = 1
        dashes.lineDashPattern = [3, 3]
        dashes.fillColor = nil
        contentView.layer.addSublayer(dashes)
        NSLayoutConstraint.activate([
            spine.topAnchor.constraint(equalTo: contentView.topAnchor),
            spine.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            spine.leadingAnchor.constraint(
                equalTo: contentView.safeAreaLayoutGuide.leadingAnchor,
                constant: RosterMetrics.inset + RosterMetrics.spine
            ),
            spine.widthAnchor.constraint(equalToConstant: 1),
            contentView.heightAnchor.constraint(equalToConstant: RosterMetrics.pinBreak),
        ])
        // A layer's colour is a CGColor, which doesn't follow the appearance on its own.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: Self, _) in
            cell.setNeedsLayout()
        }
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let insets = contentView.safeAreaInsets
        let start = insets.left + RosterMetrics.inset + RosterMetrics.spine
        let end = contentView.bounds.width - insets.right - RosterMetrics.inset
        let middle = (contentView.bounds.height / 2).rounded() + 0.5
        let path = UIBezierPath()
        path.move(to: CGPoint(x: start, y: middle))
        path.addLine(to: CGPoint(x: max(start, end), y: middle))
        dashes.path = path.cgPath
        dashes.strokeColor = UIColor.rosterGuide.resolvedColor(with: traitCollection).cgColor
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = .rosterGround
        backgroundConfiguration = background
    }
}
