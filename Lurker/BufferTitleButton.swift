// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The floating title pill: an indicator light and the buffer's name.
///
/// It goes in `navigationItem.titleView` rather than being floated over the content in a
/// container of our own. An iOS 26 navigation bar is *already* a glass layer with no
/// background that content scrolls under — hand-floating a pill would mean reimplementing
/// safe-area placement, the scroll edge effect, Dynamic Type, and glass's automatic
/// light/dark contrast switching, and would land further from Messages, not closer.
///
/// No chevron. It carried a `chevron.down` while the pill *was* the way to the buffer
/// list; that list has its own button on the leading side now, so the glyph was left
/// promising a pull-down menu this isn't. The pill is still tappable — it's a glass
/// capsule in a navigation bar, which is already the affordance.
final class BufferTitleButton: UIButton {

    /// The status light. A plain view rather than a symbol in the title, so it can't be
    /// re-flowed or re-tinted by the title's text attributes.
    private let light = UIView()
    private static let lightSize: CGFloat = 9

    init(onTap: @escaping () -> Void) {
        super.init(frame: .zero)
        addAction(UIAction { _ in onTap() }, for: .touchUpInside)

        var config = UIButton.Configuration.glass()
        // Leading inset leaves room for the light, which sits outside the configuration's
        // content and so isn't accounted for by its own layout. Trailing matches it, so
        // the name sits centred in what's left rather than crowding the trailing edge.
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 26, bottom: 6, trailing: 14)
        // A pill is a single line by definition — a long channel name truncates rather
        // than wrapping the capsule to two lines or breaking mid-word.
        config.titleLineBreakMode = .byTruncatingTail
        configuration = config

        // Yield when squeezed instead of insisting on the width a long name wants.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        light.layer.cornerRadius = Self.lightSize / 2
        light.isUserInteractionEnabled = false
        light.translatesAutoresizingMaskIntoConstraints = false
        addSubview(light)
        NSLayoutConstraint.activate([
            light.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            light.centerYAnchor.constraint(equalTo: centerYAnchor),
            light.widthAnchor.constraint(equalToConstant: Self.lightSize),
            light.heightAnchor.constraint(equalToConstant: Self.lightSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// How much of the bar the pill may claim before its title starts truncating. The rest
    /// belongs to the buttons either side of it.
    private static let maxWidthFraction: CGFloat = 0.5

    /// A `titleView` is laid out from its intrinsic size, so left alone a long channel
    /// name asks for more width than the bar has and crowds the buttons flanking it. Cap
    /// the ask; `titleLineBreakMode` truncates the name inside whatever's granted.
    override var intrinsicContentSize: CGSize {
        var size = super.intrinsicContentSize
        if let available = window?.bounds.width {
            size.width = min(size.width, available * Self.maxWidthFraction)
        }
        return size
    }

    /// What's currently rendered, so an unchanged update costs nothing.
    private var shown: (title: String, status: StatusLight)?

    func update(title: String, status: StatusLight) {
        // This is called from every state change — i.e. once per arriving message on a busy
        // channel — while the title is fixed for the screen's life and the light only moves
        // on connection transitions. Reassigning `configuration` schedules a button
        // reconfiguration and the invalidate below relayouts the whole navigation bar, so
        // without this guard each message would pay for a bar relayout that changes nothing.
        guard shown?.title != title || shown?.status != status else { return }
        shown = (title, status)

        // One font size app-wide; the pill earns its emphasis with weight, not size.
        var attributed = AttributedString(title)
        attributed.font = UIFont.preferredFont(forTextStyle: .subheadline).semibold
        attributed.foregroundColor = UIColor.label
        configuration?.attributedTitle = attributed
        // The name drives the pill's width, and the cap above is applied on measure.
        invalidateIntrinsicContentSize()

        light.backgroundColor = Palette.color(for: status)
        // The light is a color-only signal, so it has to be spoken too.
        accessibilityLabel = "\(title), \(status.spoken)"
        accessibilityHint = "Shows this buffer's info and settings"
    }
}

private extension StatusLight {
    /// What the light means, for VoiceOver. Deliberately vague about *why* it's red — the
    /// light itself doesn't carry the reason, and guessing one would be worse than not
    /// saying.
    var spoken: String {
        switch self {
        case .good: "connected"
        case .warn: "connecting"
        case .bad: "not connected"
        }
    }
}
