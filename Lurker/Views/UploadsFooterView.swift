// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// The one sentence the uploads grid ever puts under itself: the starred view came back at the
/// server's ceiling, so there may be more it didn't send (#138).
///
/// Said out loud rather than swallowed. A list that quietly stops at 200 reads as "these are all
/// of your starred uploads", which would be a lie — and unlike every other view here the starred
/// one has no cursor, so there is no "load more" to discover the rest with.
final class UploadsFooterView: UICollectionReusableView {
    static let reuseID = "UploadsFooter"

    private let label = UILabel()

    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            // Less-than, so the estimated boundary item can measure the label and take whatever
            // height it needs at any text size.
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }
}
