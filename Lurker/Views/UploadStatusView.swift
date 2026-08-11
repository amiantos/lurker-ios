// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The in-flight upload readout: a floating glass capsule above the composer that names the
/// phase ("Compressing…", "Uploading… 42%") and offers a cancel. Same `UIGlassEffect`
/// capsule family as the connection banner and the composer's buttons, so it reads as one
/// set of floating controls — but unlike the connection banner this one is interactive, so
/// the cancel button can be tapped.
final class UploadStatusView: UIView {

    /// Tapped the cancel button.
    var onCancel: (() -> Void)?

    /// What the upload is doing, in the order it happens. `preparing` covers the silent
    /// stretch before anything can report progress — the picker exporting the asset out of the
    /// photo library (a download, if it's an iCloud video) and staging it. Compression
    /// progress is coarse (the transcode reports it only loosely); the device→server upload
    /// leg is a real fraction.
    ///
    /// The last two are the server's own legs, narrated over the WS (#47). A percentage
    /// appears only where one is real: `processing` is a native one-shot with nothing to
    /// count, and `sending` has a number only when the uploader driver reports bytes. An
    /// indeterminate label is honest about an unmeasurable phase; the "Uploading… 100%" that
    /// used to sit there through both of these was not.
    enum Phase {
        case preparing
        case compressing(Double)
        case uploading(Double)
        case processing
        case sending(fraction: Double?, destination: String?)
    }

    /// Which file of how many, when a pick produced more than one. Shown as a prefix rather
    /// than folded into each phase's wording, because it's true of every phase and the
    /// alternative is five labels that each have to remember to say it.
    struct Batch {
        /// 1-based, to be read aloud ("2 of 4"), not indexed with.
        let index: Int
        let count: Int
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
        // Truncate the MIDDLE, not the tail. The capsule is centred with 16pt of margin, so a
        // long provider label (operators name their own uploaders) plus an accessibility text
        // size can outgrow it — and tail truncation would eat the percentage, which is the one
        // part of "Sending to Some Long Name… 42%" that changes and the part being watched.
        label.lineBreakMode = .byTruncatingMiddle
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

    func update(_ phase: Phase, in batch: Batch? = nil) {
        switch phase {
        case .preparing:
            label.text = "Preparing…"
        case .compressing(let fraction):
            label.text = fraction > 0.01 ? "Compressing… \(percent(fraction))" : "Compressing…"
        case .uploading(let fraction):
            label.text = "Uploading… \(percent(fraction))"
        case .processing:
            label.text = "Processing…"
        case .sending(let fraction, let destination):
            // Name the provider when the server told us which one, so the long wait is
            // legibly "this is going to Catbox" rather than an anonymous stall.
            let sendingTo = destination.map { "Sending to \($0)" } ?? "Sending"
            label.text = fraction.map { "\(sendingTo)… \(percent($0))" } ?? "\(sendingTo)…"
        }
        // Only when there is genuinely more than one — a lone "1/1" on every single-file
        // upload would be noise dressed as information.
        if let batch, batch.count > 1 {
            label.text = "\(batch.index)/\(batch.count) · \(label.text ?? "")"
            // Spoken in full: "1/4" reads as a fraction or a date, and the slash is a visual
            // shorthand that shouldn't survive into speech.
            label.accessibilityLabel = "File \(batch.index) of \(batch.count). \(spokenPhase(label.text))"
        } else {
            label.accessibilityLabel = label.text
        }
    }

    /// The label minus the batch prefix, for VoiceOver — which gets the position as a sentence
    /// of its own rather than hearing the glyph.
    private func spokenPhase(_ text: String?) -> String {
        guard let text, let separator = text.range(of: " · ") else { return text ?? "" }
        return String(text[separator.upperBound...])
    }

    func present(_ phase: Phase, in batch: Batch? = nil) {
        update(phase, in: batch)
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

extension UploadStatusView.Phase {
    /// The readout for an upload's folded progress. The two on-device phases (`preparing`,
    /// `compressing`) happen before an upload exists, so `UploadProgress` doesn't model them
    /// and this conversion never produces them.
    init(_ progress: UploadProgress) {
        switch progress.stage {
        case .uploading: self = .uploading(progress.deviceFraction)
        case .processing: self = .processing
        case .sending: self = .sending(fraction: progress.sentFraction, destination: progress.destination)
        }
    }
}
