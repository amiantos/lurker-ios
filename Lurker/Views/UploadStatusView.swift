// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// The in-flight upload readout: a floating glass capsule above the composer that names the
/// phase ("Compressing…", "Uploading… 42%") and offers a cancel. Same `UIGlassEffect`
/// capsule family as the connection banner and the composer's buttons, so it reads as one
/// set of floating controls — but unlike the connection banner this one is interactive, so
/// the cancel button can be tapped.
final class UploadStatusView: UIView {

    /// Tapped the cancel button.
    var onCancel: (() -> Void)?

    /// What the upload is doing. `preparing` covers the silent stretch before anything can
    /// report progress — the picker exporting the asset out of the photo library (a download,
    /// if it's an iCloud video) and staging it. Compression progress is coarse (the transcode
    /// reports it only loosely); the device→server upload leg is a real fraction.
    enum Phase {
        case preparing
        case compressing(Double)
        case uploading(Double)
    }

    private let glass = UIVisualEffectView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let cancelButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)

        glass.effect = UIGlassEffect()
        glass.cornerConfiguration = .capsule()
        glass.translatesAutoresizingMaskIntoConstraints = false

        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false

        label.font = UIFont.preferredFont(forTextStyle: .subheadline).semibold
        label.textColor = .label
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "xmark")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        config.baseForegroundColor = .secondaryLabel
        config.contentInsets = .zero
        cancelButton.configuration = config
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        cancelButton.accessibilityLabel = "Cancel upload"

        let stack = UIStackView(arrangedSubviews: [spinner, label, cancelButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        glass.contentView.addSubview(stack)
        addSubview(glass)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),

            cancelButton.widthAnchor.constraint(equalToConstant: 24),
            cancelButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        isAccessibilityElement = false
        alpha = 0
        isHidden = true
        transform = Self.tuckedDown
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    func update(_ phase: Phase) {
        switch phase {
        case .preparing:
            label.text = "Preparing…"
        case .compressing(let fraction):
            label.text = fraction > 0.01 ? "Compressing… \(percent(fraction))" : "Compressing…"
        case .uploading(let fraction):
            label.text = "Uploading… \(percent(fraction))"
        }
        label.accessibilityLabel = label.text
    }

    func present(_ phase: Phase) {
        update(phase)
        guard isHidden || alpha < 1 else { return }
        isHidden = false
        UIView.animate(
            withDuration: 0.3, delay: 0,
            usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
            options: [.beginFromCurrentState]
        ) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    func dismiss() {
        guard !isHidden else { return }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState]) {
            self.alpha = 0
            self.transform = Self.tuckedDown
        } completion: { _ in
            if self.alpha == 0 { self.isHidden = true }
        }
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
    }

    /// Rests just below its final spot so it slides up into place from over the composer.
    private static let tuckedDown = CGAffineTransform(translationX: 0, y: 12)
}
