// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// A centered placeholder for a surface that has nothing to show yet: a glyph *or* a
/// spinner, a title, and an optional subtitle. The chat message list is the first caller
/// (#19); the buffer switcher and member list are the obvious next ones, so this takes a
/// model rather than baking in any one screen's copy — a reusable primitive, per house
/// style, not a chat-specific view.
///
/// Sized to be dropped in as a `UITableView.backgroundView`: it fills the table and centers
/// its content, and the table hides it the moment there are cells to draw over it.
///
/// Type follows the app's single-size rule — everything is `.subheadline`, and the hierarchy
/// is carried by color and weight, not size (the glyph does the rest of the work).
final class StateView: UIView {

    /// What to show. `isLoading` swaps the glyph for a spinner — the two never appear at
    /// once, because "we're fetching" and "here's an icon for the empty result" are
    /// different moments.
    struct Model: Equatable {
        var symbol: String?
        var title: String
        var subtitle: String?
        var isLoading: Bool

        init(symbol: String? = nil, title: String, subtitle: String? = nil, isLoading: Bool = false) {
            self.symbol = symbol
            self.title = title
            self.subtitle = subtitle
            self.isLoading = isLoading
        }
    }

    private let spinner = UIActivityIndicatorView(style: .large)
    private let glyph = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        glyph.contentMode = .scaleAspectFit
        glyph.tintColor = .tertiaryLabel
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        glyph.setContentHuggingPriority(.required, for: .vertical)

        spinner.color = .secondaryLabel
        spinner.hidesWhenStopped = true

        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).semibold
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true

        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .tertiaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.adjustsFontForContentSizeCategory = true

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        // The glyph/spinner want a touch more air above the text than the two labels want
        // between themselves; a custom spacing after the top element gives it without a
        // second stack.
        stack.addArrangedSubview(glyph)
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.setCustomSpacing(14, after: glyph)
        stack.setCustomSpacing(14, after: spinner)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Keep the copy off the edges and give the subtitle a sane wrap width rather
            // than letting a long line run the full table width.
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    func configure(_ model: Model) {
        if model.isLoading {
            spinner.startAnimating() // hidesWhenStopped handles visibility
            glyph.isHidden = true
        } else {
            spinner.stopAnimating()
            glyph.image = model.symbol.flatMap { UIImage(systemName: $0) }
            glyph.isHidden = glyph.image == nil
        }
        titleLabel.text = model.title
        subtitleLabel.text = model.subtitle
        subtitleLabel.isHidden = model.subtitle == nil
    }
}
