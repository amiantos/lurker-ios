// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit
import UniformTypeIdentifiers

/// The composer's text view, subclassed for two reasons: intercept an **image paste** (#14), and
/// own the **hardware keyboard's** Return and Tab (lurker-android#63).
///
/// Copy a screenshot and paste it here and it should upload, not drop a text attachment into
/// the field. Everything else — a text paste included — falls straight through to
/// `UITextView`.
///
/// The key commands live on the text view itself rather than on the screen, so they're in the
/// responder chain only while it is first responder: nothing else on the screen loses Return or
/// Tab, and the on-screen keyboard never sees them (it types through `insertText`, not presses).
final class ComposerTextView: UITextView {

    /// A pasted image: original bytes, the sniffed mime, and a filename. Bytes rather than a
    /// re-encoded `UIImage`, so a PNG screenshot stays a lossless PNG and the server sees
    /// exactly what was copied. Empty tuple positions are (data, mime, filename).
    var onPasteImage: ((Data, String, String) -> Void)?
    /// Whether an image paste uploads. Off where the buffer takes no files (a server log, the
    /// Lurker buffer): there a paste is an ordinary text paste, rather than an image swallowed.
    var acceptsImages = true

    /// Offer "Paste" whenever the pasteboard holds an image, even with no text on it — so a
    /// copied screenshot is pasteable into an empty field. `hasImages` is a detection
    /// property, so probing it here doesn't trip the "pasted from" privacy banner; only the
    /// real read in `paste(_:)` does.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // ⚠ Never during an IME composition: Return commits it and Tab may drive its candidates,
        // so the keys are the IME's. Unable to perform, a command stands aside and the key goes
        // where it otherwise would — the same switch `ChatViewController` uses for Escape.
        if Self.keyboardActions.contains(action) { return markedTextRange == nil }
        if action == #selector(paste(_:)), acceptsImages, UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if acceptsImages, let pasted = Self.imageFromPasteboard() {
            onPasteImage?(pasted.data, pasted.mime, pasted.filename)
            return
        }
        isPasting = true
        defer { isPasting = false }
        super.paste(sender)
    }

    /// Set while a text paste goes in, so "Enter to send" (lurker-android#64) doesn't read a
    /// pasted lone newline as the Return key — it comes through `shouldChangeTextIn` the same way.
    private(set) var isPasting = false

    // MARK: - Hardware keyboard (lurker-android#63)

    /// Return without Shift: send, down the Send button's path. Ctrl, Option and Cmd don't
    /// matter, as on the web.
    var onHardwareReturn: (() -> Void)?
    /// Tab, or Shift-Tab (`true`): complete the word under the caret.
    var onTab: ((_ backward: Bool) -> Void)?
    /// Set while Shift-Return's newline goes in. The delegate reads it so "Enter to send"
    /// (lurker-android#64), which turns a `"\n"` into a send, doesn't send this one: our own
    /// `insertText` comes through `shouldChangeTextIn` exactly as the on-screen Return does.
    private(set) var isInsertingHardwareNewline = false

    private static let keyboardActions: Set<Selector> = [
        #selector(ComposerTextView.hardwareReturn), #selector(ComposerTextView.hardwareNewline),
        #selector(ComposerTextView.tabForward), #selector(ComposerTextView.tabBackward),
    ]

    /// Built once and always returned. ⚠ UIKit caches a responder's `keyCommands`, so a list that
    /// changed with the field's state wouldn't reliably be seen; `canPerformAction` is the switch.
    ///
    /// ⚠ `wantsPriorityOverSystemBehavior` on every one, or the text system takes Return and Tab
    /// first and these never fire. That's also what keeps a hardware Return from reaching
    /// `shouldChangeTextIn` as a `"\n"`, where "Enter to send" would handle it a second time.
    ///
    /// ⚠ A command matches its modifier flags exactly, so "other modifiers don't matter" means a
    /// command per combination: Cmd/Ctrl/Option as on the web, plus Caps Lock, and `.numericPad`,
    /// the flag every keypad key carries — the keypad's Enter is expected as the same `"\r"` with
    /// it set. (Unverified on hardware: a keypad Enter that does nothing is where to look.)
    private lazy var hardwareKeyCommands: [UIKeyCommand] = {
        func command(_ input: String, _ flags: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        let returns = Self.combinations(of: [.command, .control, .alternate, .alphaShift, .numericPad])
            .flatMap { flags in
                [command("\r", flags, #selector(hardwareReturn)),
                 command("\r", flags.union(.shift), #selector(hardwareNewline))]
            }
        let tabs = Self.combinations(of: [.alphaShift]).flatMap { flags in
            [command("\t", flags, #selector(tabForward)), command("\t", flags.union(.shift), #selector(tabBackward))]
        }
        return returns + tabs
    }()

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + hardwareKeyCommands
    }

    @objc private func hardwareReturn() { onHardwareReturn?() }

    @objc private func hardwareNewline() {
        isInsertingHardwareNewline = true
        defer { isInsertingHardwareNewline = false }
        insertText("\n")
    }

    // ⚠ Tab is always taken, matched or not: let through, it would insert a tab character or walk
    // focus out of the composer.
    @objc private func tabForward() { onTab?(false) }
    @objc private func tabBackward() { onTab?(true) }

    /// Every combination of `flags`, the empty one included.
    private static func combinations(of flags: [UIKeyModifierFlags]) -> [UIKeyModifierFlags] {
        (0..<(1 << flags.count)).map { mask in
            flags.indices.reduce(into: UIKeyModifierFlags()) { result, bit in
                if mask & (1 << bit) != 0 { result.formUnion(flags[bit]) }
            }
        }
    }

    private static func imageFromPasteboard() -> (data: Data, mime: String, filename: String)? {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasImages else { return nil }
        // Prefer the original bytes in a known raster type so a screenshot stays a lossless
        // PNG; only fall back to a re-encode if the pasteboard vends nothing we recognize.
        for type in [UTType.png, .jpeg, .heic, .gif, .tiff, .webP] {
            if let data = pasteboard.data(forPasteboardType: type.identifier), !data.isEmpty {
                let ext = type.preferredFilenameExtension ?? "png"
                return (data, type.preferredMIMEType ?? "image/png", "pasted-image.\(ext)")
            }
        }
        if let image = pasteboard.image, let data = image.pngData() {
            return (data, "image/png", "pasted-image.png")
        }
        return nil
    }
}
