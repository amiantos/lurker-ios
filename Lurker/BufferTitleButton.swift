// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The floating title pill, in the shape Messages uses: an indicator light, the buffer's
/// name, and a chevron saying it opens something.
///
/// It goes in `navigationItem.titleView` rather than being floated over the content in a
/// container of our own. An iOS 26 navigation bar is *already* a glass layer with no
/// background that content scrolls under — hand-floating a pill would mean reimplementing
/// safe-area placement, the scroll edge effect, Dynamic Type, and glass's automatic
/// light/dark contrast switching, and would land further from Messages, not closer.
///
/// The chevron points down, not right like Messages': Messages opens a details *page* for
/// the current conversation, while this opens a picker for a different one. Down is the
/// system's pull-down-menu affordance, which is what this actually is.
final class BufferTitleButton: UIButton {

    /// The status light. A plain view rather than a symbol in the title, so it can't be
    /// re-flowed or re-tinted by the title's text attributes.
    private let light = UIView()
    private static let lightSize: CGFloat = 9

    init(onTap: @escaping () -> Void) {
        super.init(frame: .zero)
        addAction(UIAction { _ in onTap() }, for: .touchUpInside)

        var config = UIButton.Configuration.glass()
        config.image = UIImage(systemName: "chevron.down")
        config.imagePlacement = .trailing
        config.imagePadding = 5
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .small)
        // Leading inset leaves room for the light, which sits outside the configuration's
        // content and so isn't accounted for by its own layout.
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 26, bottom: 6, trailing: 12)
        configuration = config

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

    func update(title: String, status: StatusLight) {
        // One font size app-wide; the pill earns its emphasis with weight, not size.
        var attributed = AttributedString(title)
        attributed.font = UIFont.preferredFont(forTextStyle: .subheadline).semibold
        attributed.foregroundColor = UIColor.label
        configuration?.attributedTitle = attributed

        light.backgroundColor = Palette.color(for: status)
        // The light is a color-only signal, so it has to be spoken too.
        accessibilityLabel = "\(title), \(status.spoken)"
        accessibilityHint = "Opens the buffer list"
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
