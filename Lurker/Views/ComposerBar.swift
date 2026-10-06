// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The message composer, in the shape Messages uses: a glass field that grows with the
/// text, flanked by a paperclip and a round send button. It floats over the conversation
/// rather than sitting on an opaque bar — the same iOS 26 glass the nav bar
/// uses — so the messages scroll *under* it and off the bottom of the screen.
///
/// The three pieces live in one `UIGlassContainerEffect`, which gives them a shared
/// sampling region: at rest they read as three separate pills, but interacting with one
/// bleeds its glass toward its neighbors instead of each sitting in its own sealed pane.
/// That grouping is why the field and buttons are each a `UIVisualEffectView` with its own
/// `UIGlassEffect` rather than glass-configured `UIButton`s — a glass button doesn't join
/// the container.
///
/// A `UITextView`, not a `UITextField`, for two reasons the redesign turns on: it grows to
/// several lines, and Return inserts a newline. On the on-screen keyboard that stays the default,
/// so a multi-line message is something you can actually type; "Enter to send"
/// (lurker-android#64) makes Return send instead. A hardware keyboard's Enter always sends and
/// Shift-Enter starts a line (lurker-android#63) — there's a Shift key to ask for the newline with.
final class ComposerBar: UIView {

    /// Called with the trimmed text when the send button is tapped, or a key sends (`fire()`).
    /// The bar does not clear itself — the owner does, once the send is accepted, via `clear()`.
    var onSend: ((String) -> Void)?

    /// Tapped the paperclip.
    var onAttach: (() -> Void)?

    /// Pasted an image into the field (#14) — original bytes, mime, filename. The owner
    /// uploads it; the composer never drops the image inline.
    var onPasteImage: ((Data, String, String) -> Void)?

    /// Fired when the intrinsic height changes (a line added or removed), so the owner can
    /// re-inset the conversation under the grown bar.
    var onHeightChange: (() -> Void)?

    /// What kind of completion is live under the caret. The composer detects the *shape*
    /// (`CommandCompletion` for a slash line, `NickCompletion` for a nick) and reports the
    /// query; the owner turns that into candidates and floats the pills.
    enum Completion: Equatable {
        /// Typing the command verb — `/jo|`. `query` excludes the slash.
        case command(query: String)
        /// Typing a channel argument of a command — `/join #li|`, `/part #|`.
        case channelArg(query: String)
        /// Typing a nick argument of a command — `/msg al|`, `/whois b|`.
        case nickArg(query: String)
        /// A nick being typed — `@al|`, or a bare `al|` (lurker-android#57) — anywhere free text is
        /// allowed, including inside `/me …`.
        case mention(query: String)
    }

    /// Fired when the completion context under the caret changes, nil when there isn't one.
    /// The owner floats the suggestion pills; the bar only reports the token.
    var onCompletion: ((Completion?) -> Void)?

    /// Fired whenever the field's text changes, with the current draft — including the
    /// programmatic changes (`clear()` after a send, a completion insert), because those are
    /// changes to what the user is composing too. Drives the outgoing typing signal (#61).
    var onDraftChange: ((String) -> Void)?
    /// Fired when the user changes the field — its text, or whether an IME is composing in it —
    /// for the synced draft (iOS #188). Unlike `onDraftChange`, never for a `restore`: the owner
    /// put that text there and knows what it is. And not deduped against what the CHANNEL was
    /// told, which a restore leaves behind — emptying a restored draft is an edit.
    var onEdit: (() -> Void)?
    /// The field stopped being edited — the keyboard went away.
    var onEndEditing: (() -> Void)?
    /// The pending-reply bar's ×.
    var onCancelReply: (() -> Void)?
    /// The away strip's Back (#135).
    var onBack: (() -> Void)?

    /// What a hardware Tab completes against (lurker-android#63), asked fresh on each Tab that
    /// starts a completion. The owner's, because the roster, the network's channels and the
    /// suffix setting live on the store, which this view has no window onto.
    struct TabSource {
        /// Nick candidates for what's typed, best first — enough of them to cycle through.
        let nicks: (String) -> [String]
        /// The network's channels, best first — asked only for a `#` word.
        let channels: () -> [String]
        /// `NickCompletion.addressPunctuation` of the live settings.
        let punctuation: String
    }
    var tabSource: (() -> TabSource?)?
    /// The completion Tab is cycling, if any. Any edit or caret move Tab didn't make ends it, as
    /// any other key does on the web — `continues` alone would revive it after a letter typed and
    /// deleted. While it lives the pill strip stays down: the web closes its pickers on Tab, and a
    /// mid-sentence completion would otherwise float pills over the nick it just finished.
    private var tabCompletion: TabCompletion?
    /// Set while Tab's own edit goes in, so the change callbacks don't end the session it belongs to.
    private var isApplyingTab = false

    /// The draft as of the last `onDraftChange` (or `restore`), so a re-measure that changes no
    /// text doesn't masquerade as an edit. See `textViewDidChange`.
    private var lastEmittedDraft = ""

    /// Set while `restore(_:)` is putting a refused line back — see its note.
    private var isRestoring = false

    /// The field as `onEdit` last saw it, so a re-measure or a caret move isn't an edit.
    private var lastEdit = (text: "", composing: false)

    var placeholder: String = "" {
        didSet { placeholderLabel.text = placeholder }
    }

    /// Whether the paperclip shows. The system buffer composes commands, not messages —
    /// there's nothing to attach — so it drops the pill and the field takes the width.
    var showsAttach: Bool = true {
        didSet {
            guard showsAttach != oldValue else { return }
            attachGlass.isHidden = !showsAttach
            // No paperclip, no image paste either — the same rule, from the keyboard.
            textView.acceptsImages = showsAttach
            // Deactivate before activate, or the two leading constraints briefly conflict.
            (showsAttach ? fieldFlushLeading : fieldAfterAttach)?.isActive = false
            (showsAttach ? fieldAfterAttach : fieldFlushLeading)?.isActive = true
        }
    }

    private let container = UIVisualEffectView(effect: ComposerBar.containerEffect())
    private let attachGlass = UIVisualEffectView()
    private let fieldGlass = UIVisualEffectView()
    private let sendGlass = UIVisualEffectView()
    private let textView = ComposerTextView()
    private let placeholderLabel = UILabel()
    private let attachButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    /// The strip above the field. It says one of two things:
    ///
    /// - The pending reply (iOS #184): "Replying to alice  ×". The web keeps it in its status
    ///   bar; iOS has none, and this is where Messages, Discord and Telegram all put it —
    ///   attached to the thing it changes.
    /// - That you're away (#135): "Away since 2:32 PM · lunch  Back". The indicator and the way
    ///   out are one control, so getting back doesn't depend on remembering `/back`.
    ///
    /// The reply wins while one is pending — it's what the next send does — and the away strip
    /// comes back once it's spent or cancelled. One slot rather than two stacked strips, which
    /// would eat into the little conversation a phone shows above the keyboard.
    private let strip = UIVisualEffectView()
    private let stripLabel = UILabel()
    private let stripButton = UIButton(type: .system)
    private var reply: PendingReply?
    private var away: AwayState?
    /// `away`'s words, built when it or the clock changes rather than on every render — a
    /// reply shown or cancelled, a Dynamic Type change — since building them means a
    /// `DateFormatter`.
    private var awayText: AwayStrip?
    private var containerBelowStrip: NSLayoutConstraint!
    private var containerAtTop: NSLayoutConstraint!

    /// How tall the text may grow before it scrolls internally instead. Five lines is the
    /// Messages ceiling too — past that you're writing a paragraph, and the conversation
    /// behind the bar has given up enough room.
    private static let maxLines = 5
    /// The gap between the three glass pills.
    private static let gap: CGFloat = 8
    /// The text view's own inset. The placeholder is pinned to *these* exact values so it
    /// sits where the first typed character will, not merely somewhere near it.
    private static let textInset = UIEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
    /// The symbol size in the round buttons — small enough to read as an icon with air
    /// around it, like Messages'. Internal because `JumpToLatestButton` draws its glyph
    /// to the same metric, for the same reason it borrows `collapsedHeight`.
    static let glyph = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)

    /// The height of the collapsed field: exactly one line of body text plus its inset.
    /// Used as the field's floor *and* the round pills' size, so the empty bar and the
    /// one-line bar are the same height — otherwise the field would jump a couple of points
    /// the instant you typed, because a fixed floor never quite matches a real line.
    ///
    /// Internal rather than private: `JumpToLatestButton` floats directly above the send
    /// button and matches its diameter through this — two circles a few points apart at
    /// different sizes read as a mistake.
    static var collapsedHeight: CGFloat {
        ceil(UIFont.preferredFont(forTextStyle: .body).lineHeight) + textInset.top + textInset.bottom
    }
    private var textHeight: NSLayoutConstraint!
    /// The pills' width/height constraints, kept so a Dynamic Type change can resize them.
    private var pillSizeConstraints: [NSLayoutConstraint] = []
    /// The field's two possible leading edges — beside the paperclip, or flush to the
    /// container when `showsAttach` drops it. Exactly one is active at a time.
    private var fieldAfterAttach: NSLayoutConstraint!
    private var fieldFlushLeading: NSLayoutConstraint!
    /// Whether the send button is currently in its active (accent) state, so its glass
    /// effect is only rebuilt when that flips — not on every keystroke.
    private var sendActive: Bool?
    /// The last completion context handed to `onCompletion`, so keystrokes and caret moves
    /// that don't change the answer don't re-fire it. Wrapped in an extra optional to
    /// distinguish "not computed yet" from "computed, and it's nil".
    private var lastCompletion: Completion??

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Match the message bubbles' horizontal inset, so the group's edges line up with
        // the column of bubbles above it rather than sitting a few points proud of them. A
        // bare view defaults to an 8pt margin; a table cell's content uses the system 16,
        // which is what the bubbles get.
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        container.translatesAutoresizingMaskIntoConstraints = false

        // The field: a fixed radius, not `.capsule()`. A capsule's radius is half its
        // height, right at one line — but as the field grows the radius grows with it until
        // the corners are huge arcs that clip the text top and bottom. Pinned to half the
        // single-line height, it's a capsule when short and a rounded rectangle when tall.
        fieldGlass.effect = Self.glass()
        fieldGlass.cornerConfiguration = .corners(radius: .fixed(Self.collapsedHeight / 2))
        fieldGlass.translatesAutoresizingMaskIntoConstraints = false

        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = Self.textInset
        textView.textContainer.lineFragmentPadding = 0
        // `.default`, not `.yes`: the user's system-wide autocorrect preference stays the
        // boss. Capitalization is its own switch (`applyKeyboardPreferences`) — UIKit keeps
        // the two independent, which is the pairing the web client can't offer, since Safari
        // re-applies sentence caps whenever correction is on.
        textView.autocorrectionType = .default
        textView.isScrollEnabled = false // until it hits the cap; see textViewDidChange
        textView.delegate = self
        textView.onPasteImage = { [weak self] data, mime, name in self?.onPasteImage?(data, mime, name) }
        textView.onHardwareReturn = { [weak self] in self?.fire() }
        textView.onTab = { [weak self] backward in self?.tabComplete(backward: backward) }
        textView.translatesAutoresizingMaskIntoConstraints = false
        applyKeyboardPreferences()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyKeyboardPreferences),
            name: .composerKeyboardPreferencesDidChange, object: nil
        )
        // "Away since 2:32 PM" stops being true at midnight (it needs the date), on a time zone
        // or DST change (it's another hour), and on a region change (another format). The first
        // covers the first three.
        for name in [UIApplication.significantTimeChangeNotification, NSLocale.currentLocaleDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(dateFormatChanged), name: name, object: nil)
        }

        // A UITextView has no placeholder of its own, so it's a label pinned inside — at the
        // text container's own origin, in the text view's own font, so it's indistinguishable
        // from a caret on an empty line. Hidden the moment there's text.
        placeholderLabel.font = textView.font
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        configureRoundGlass(attachGlass, button: attachButton, symbol: "paperclip")
        attachButton.addAction(UIAction { [weak self] _ in self?.onAttach?() }, for: .touchUpInside)

        configureRoundGlass(sendGlass, button: sendButton, symbol: "arrow.up")
        sendButton.addAction(UIAction { [weak self] _ in self?.fire() }, for: .touchUpInside)

        strip.effect = Self.glass()
        strip.cornerConfiguration = .corners(radius: .fixed(22))
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.isHidden = true
        stripLabel.font = .preferredFont(forTextStyle: .footnote)
        stripLabel.adjustsFontForContentSizeCategory = true
        stripLabel.lineBreakMode = .byTruncatingTail
        stripLabel.translatesAutoresizingMaskIntoConstraints = false
        stripButton.translatesAutoresizingMaskIntoConstraints = false
        stripButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // What the strip is showing NOW, not what it showed when the action was built.
            if reply != nil { onCancelReply?() } else { onBack?() }
        }, for: .touchUpInside)
        stripButton.setContentHuggingPriority(.required, for: .horizontal)
        stripButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        strip.contentView.addSubview(stripLabel)
        strip.contentView.addSubview(stripButton)
        addSubview(strip)

        fieldGlass.contentView.addSubview(textView)
        fieldGlass.contentView.addSubview(placeholderLabel)
        container.contentView.addSubview(attachGlass)
        container.contentView.addSubview(fieldGlass)
        container.contentView.addSubview(sendGlass)
        addSubview(container)

        let content = container.contentView
        let pill = Self.collapsedHeight
        textHeight = textView.heightAnchor.constraint(equalToConstant: pill)
        // The round pills are sized to the field's one-line height so all three match. That
        // height tracks Dynamic Type, so these constants have to move with it (see
        // `updateMetrics`) — kept in one place for that.
        pillSizeConstraints = [
            attachGlass.widthAnchor.constraint(equalToConstant: pill),
            attachGlass.heightAnchor.constraint(equalToConstant: pill),
            sendGlass.widthAnchor.constraint(equalToConstant: pill),
            sendGlass.heightAnchor.constraint(equalToConstant: pill),
        ]
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: fieldGlass.contentView.topAnchor),
            textView.bottomAnchor.constraint(equalTo: fieldGlass.contentView.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: fieldGlass.contentView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: fieldGlass.contentView.trailingAnchor),
            textHeight,

            // Exactly the text container's origin — same inset the glyphs use.
            placeholderLabel.leadingAnchor.constraint(
                equalTo: textView.leadingAnchor, constant: Self.textInset.left
            ),
            placeholderLabel.topAnchor.constraint(
                equalTo: textView.topAnchor, constant: Self.textInset.top
            ),

            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            strip.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            strip.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stripLabel.leadingAnchor.constraint(equalTo: strip.contentView.leadingAnchor, constant: 14),
            stripLabel.centerYAnchor.constraint(equalTo: strip.contentView.centerYAnchor),
            stripLabel.topAnchor.constraint(greaterThanOrEqualTo: strip.contentView.topAnchor, constant: 7),
            stripLabel.bottomAnchor.constraint(lessThanOrEqualTo: strip.contentView.bottomAnchor, constant: -7),
            stripButton.leadingAnchor.constraint(equalTo: stripLabel.trailingAnchor, constant: 4),
            stripButton.trailingAnchor.constraint(equalTo: strip.contentView.trailingAnchor),
            // The only way to cancel (or come back) by touch, so a full 44pt target — and inside the bar, which
            // sets the bar's height: a target that hung outside it would never be hit.
            stripButton.topAnchor.constraint(equalTo: strip.contentView.topAnchor),
            stripButton.bottomAnchor.constraint(equalTo: strip.contentView.bottomAnchor),
            stripButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            stripButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            container.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),

            // Both round pills sit at the *bottom* of the group, so they stay beside the
            // last line as the field grows upward rather than floating to the middle.
            attachGlass.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            attachGlass.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            fieldGlass.topAnchor.constraint(equalTo: content.topAnchor),
            fieldGlass.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            sendGlass.leadingAnchor.constraint(equalTo: fieldGlass.trailingAnchor, constant: Self.gap),
            sendGlass.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sendGlass.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ] + pillSizeConstraints)

        containerAtTop = container.topAnchor.constraint(equalTo: topAnchor, constant: 6)
        containerBelowStrip = container.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: 6)
        containerAtTop.isActive = true

        fieldAfterAttach = fieldGlass.leadingAnchor.constraint(
            equalTo: attachGlass.trailingAnchor, constant: Self.gap
        )
        fieldFlushLeading = fieldGlass.leadingAnchor.constraint(equalTo: content.leadingAnchor)
        fieldAfterAttach.isActive = true

        // Keep the pills and the field's corner radius sized to one line as the text size
        // changes under us — without this the field's floor (recomputed live in
        // `textViewDidChange`) grows on a type change while the pills stay put, and the
        // three stop matching height.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (bar: ComposerBar, _) in
            bar.updateMetrics()
        }

        updateSendEnabled()
    }

    /// Re-size the round pills and the field's corner radius to the current one-line height,
    /// then refresh the field's floor. Called on a Dynamic Type change.
    private func updateMetrics() {
        let pill = Self.collapsedHeight
        pillSizeConstraints.forEach { $0.constant = pill }
        fieldGlass.cornerConfiguration = .corners(radius: .fixed(pill / 2))
        textViewDidChange(textView)
        // Back's title is a button configuration's, which doesn't follow Dynamic Type itself.
        renderStrip()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// Read the device-local keyboard preferences onto the field: whether to capitalize
    /// sentences (`UserDefaults.composerAutocapitalizes`), and whether Return reads Send
    /// (`composerEnterSends`, lurker-android#64 — the send itself is `shouldChangeTextIn`'s).
    ///
    /// Runs at init and again on every change, because Settings is a sheet over this screen
    /// rather than a push: the composer stays alive underneath it and would otherwise keep the
    /// value it read the last time it was built, which for the buffer you were in when you
    /// flipped the switch is "never".
    @objc private func applyKeyboardPreferences() {
        let preferences = UserPreferences.standard
        let capitalization: UITextAutocapitalizationType = preferences.composerAutocapitalizes ? .sentences : .none
        let returnKey: UIReturnKeyType = preferences.composerEnterSends ? .send : .default
        guard textView.autocapitalizationType != capitalization || textView.returnKeyType != returnKey
        else { return }
        textView.autocapitalizationType = capitalization
        textView.returnKeyType = returnKey
        // A Send key greys out over an empty field, as Messages' does; a newline key never would.
        textView.enablesReturnKeyAutomatically = preferences.composerEnterSends
        // A keyboard is configured when it comes up, so a field that's focused right now is
        // already showing one built from the old value. This re-asks for it.
        if textView.isFirstResponder { textView.reloadInputViews() }
    }

    /// The locale notification doesn't promise the main thread.
    @objc private func dateFormatChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            awayText = AwayStrip.make(away)
            renderStrip()
        }
    }

    /// Show the pending reply above the field, or take it away (nil). The strip grows or
    /// shrinks the composer, so the owner hears about it the way it hears about a taller field.
    func showReply(_ reply: PendingReply?) {
        self.reply = reply
        renderStrip()
    }

    /// Show that you're away above the field, or stop (nil, or an away that isn't active).
    ///
    /// ⚠ Gated on `active` alone. `since` and `message` deliberately outlive `/back` so the
    /// dividers can draw the finished pair (see `AwayState`), so their presence says nothing.
    func showAway(_ away: AwayState?) {
        let away = away?.active == true ? away : nil
        guard away != self.away else { return }
        self.away = away
        awayText = AwayStrip.make(away)
        renderStrip()
    }

    private func renderStrip() {
        let wasShowing = !strip.isHidden
        let footnote = UIFont.preferredFont(forTextStyle: .footnote)
        stripButton.accessibilityHint = nil
        if let reply {
            let text = NSMutableAttributedString(
                string: "Replying to ",
                attributes: [.foregroundColor: UIColor.secondaryLabel]
            )
            let name = reply.isSelf ? "yourself" : reply.nick
            text.append(NSAttributedString(string: name, attributes: [
                .foregroundColor: UIColor.label, .font: footnote.bold,
            ]))
            let excerpt = Replies.excerpt(reply.text)
            if !excerpt.isEmpty {
                text.append(NSAttributedString(
                    string: ": " + excerpt, attributes: [.foregroundColor: UIColor.secondaryLabel]
                ))
            }
            stripLabel.attributedText = text
            stripLabel.accessibilityLabel = "Replying to \(name)" + (excerpt.isEmpty ? "" : ": \(excerpt)")
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: "xmark.circle.fill")
            config.baseForegroundColor = .secondaryLabel
            config.contentInsets = .zero
            stripButton.configuration = config
            stripButton.accessibilityLabel = "Cancel reply"
        } else if let label = awayText {
            let text = NSMutableAttributedString(string: label.lead, attributes: [
                .foregroundColor: UIColor.label, .font: footnote.bold,
            ])
            text.append(NSAttributedString(
                string: label.detail, attributes: [.foregroundColor: UIColor.secondaryLabel]
            ))
            stripLabel.attributedText = text
            stripLabel.accessibilityLabel = label.lead + label.detail
            var config = UIButton.Configuration.plain()
            config.title = "Back"
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFont.preferredFont(forTextStyle: .footnote).bold
                return outgoing
            }
            // Clear of the strip's rounded end, which a bare 44pt-wide title would crowd.
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 16)
            stripButton.configuration = config
            stripButton.accessibilityLabel = "Back"
            stripButton.accessibilityHint = "Clears your away status."
        }
        let showing = reply != nil || awayText != nil
        strip.isHidden = !showing
        containerAtTop.isActive = !showing
        containerBelowStrip.isActive = showing
        if wasShowing != showing { onHeightChange?() }
    }

    /// Clears the field after a send the owner accepted, and collapses it back to one line.
    func clear() {
        textView.text = ""
        textViewDidChange(textView)
    }

    /// Replace the nick being typed — an `@…` or a bare word — with the picked nick plus its
    /// addressing suffix: the web picker's exact insertion, so both clients send the same
    /// line. An `@` goes: IRC addresses by bare nick, and the sent line highlights by
    /// containing it.
    ///
    /// A pick the word under the caret no longer leads to is stale and inserts nothing. A
    /// bare word makes nearly any word a token, so "is there one" no longer tells a pick
    /// made for this word from one made for the word the caret just left.
    ///
    /// `punctuation` is the resolved `input.completion.nick_suffix`; the owner reads it,
    /// because the setting lives on the store and this view has no window onto it.
    func completeMention(with nick: String, punctuation: String) {
        let selection = textView.selectedRange
        guard selection.length == 0, !isComposing,
              let token = NickCompletion.activeMention(in: textView.text, caret: selection.location),
              nick.lowercased().hasPrefix(token.query.lowercased())
        else { return }
        let replacement = nick + NickCompletion.addressingSuffix(
            beforeTokenAt: token.start, in: textView.text, punctuation: punctuation)
        // The whole word, not just up to the caret — completing `@al|ice` must swallow
        // the tail, not weld the pick onto it.
        replaceToken(NSRange(location: token.start, length: token.end - token.start), with: replacement)
    }

    /// Replace the verb under the caret with the picked command, trailing a space so the
    /// caret lands where the first argument goes — picking `/join` leaves `/join |`, and the
    /// owner immediately floats channel chips for the empty slot.
    func completeCommand(name: String) {
        let selection = textView.selectedRange
        guard selection.length == 0,
              case .command(_, let range)? = CommandCompletion.context(in: textView.text, caret: selection.location)
        else { return }
        replaceToken(range, with: "/\(name) ")
    }

    /// Replace the channel/nick argument under the caret with the pick, trailing a space so
    /// the next argument (a key, a message, another nick) can follow.
    func completeArgument(value: String) {
        let selection = textView.selectedRange
        guard selection.length == 0,
              case .argument(_, _, _, _, let range)? = CommandCompletion.context(in: textView.text, caret: selection.location)
        else { return }
        replaceToken(range, with: "\(value) ")
    }

    /// What's in the field, as typed.
    var text: String { textView.text ?? "" }

    /// Whether an IME is mid-composition — marked text the keyboard hasn't committed yet.
    var isComposing: Bool { textView.markedTextRange != nil }

    /// Whether the field is empty — nothing typed, nothing but whitespace.
    var isEmpty: Bool {
        (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Put a refused line back, as typed (#128) — or a draft, which may be empty: another device
    /// emptied it (iOS #188).
    ///
    /// ⚠⚠ Does NOT raise the keyboard, unlike `address(_:)`. Nothing the user did asked for this
    /// — the server refused a send and the text is coming home — so shoving the keyboard up over
    /// a conversation they may have gone back to reading is the app talking over them. The text
    /// appearing in the field is the whole message.
    ///
    /// ⚠ Caret at the end, so carrying on writing works without a tap to reposition.
    func restore(_ text: String) {
        // Raised before the text moves, not just around the delegate call below: setting `text`
        // and the caret fire `textViewDidChangeSelection`, which would report the restore as an
        // edit of the user's.
        isRestoring = true
        defer { isRestoring = false }
        textView.text = text
        textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        // ⚠⚠ Silently. `textViewDidChange` is needed for the height, the send button and the
        // placeholder, but its two announcements must not fire: `onDraftChange` would tell the
        // CHANNEL you had resumed typing because the server handed your own message back, and
        // `emitCompletion` would pop the nick bar over a restored `/msg bob hi` that nobody was
        // in the middle of writing. Same hazard the method's own comment names for the Dynamic
        // Type path, arriving down a different road.
        //
        // ⚠⚠ `lastEmittedDraft` IS advanced, to the restored text: the owner ends any typing claim
        // before a restore, so the channel's picture is "not typing" over THIS text. Left at the
        // old value, a restore that lands one keystroke away from it swallowed the next one —
        // type "hello" (paused), another device trims it to "hell", type "o": the draft equals
        // what was last emitted, nothing goes out, and the channel keeps seeing "paused" while
        // you type. Deleting the restored text to empty emits an empty draft, which ends a claim
        // that isn't there: silent.
        lastEmittedDraft = text
        textViewDidChange(textView)
    }

    /// Address `nick` at the head of the draft — what Reply does (#60).
    ///
    /// Prepends the addressing form unless the draft already opens that way, keeps whatever was
    /// being typed, and leaves the caret at the end so you carry on writing rather than in front
    /// of your own words. Same insertion as the web's `addressInComposer`, so a reply reads
    /// identically whichever client sent it. Raises the keyboard, because the tap that got here
    /// was a request to write something.
    ///
    /// `punctuation` is the resolved `input.completion.nick_suffix` (#133). The
    /// already-addressed test is `NickCompletion.isAddressed`, not a `hasPrefix` on the form we
    /// are about to write: a draft can carry an older setting's mark, or the web's, and drafts
    /// sync — `hasPrefix` would stack a second address onto `bob: sure`.
    ///
    /// Returns whether it put the address there — a pending reply's cancel takes back only an
    /// address its Reply inserted (iOS #184).
    @discardableResult
    func address(_ nick: String, punctuation: String) -> Bool {
        guard !nick.isEmpty else { return false }
        let current = textView.text ?? ""
        let already = NickCompletion.isAddressed(current, to: nick, punctuation: punctuation)
        let next = already ? current : "\(nick)\(punctuation) " + current
        // Caret at the end, not after the prefix: `replaceToken` puts it where it spliced, which
        // for a prepend is in front of the existing draft.
        textView.text = next
        textView.selectedRange = NSRange(location: (next as NSString).length, length: 0)
        textViewDidChange(textView)
        becomeFirstResponder()
        return !already
    }

    /// Take back the `nick: ` a Reply put at the head of the draft — a cancelled reply's half of
    /// `address`. Anything else in the field stays, and a draft that no longer opens with it is
    /// left alone: the user has rewritten it, and it's theirs now.
    func removeAddress(_ nick: String, punctuation: String) {
        let current = textView.text ?? ""
        let next = NickCompletion.removingAddress(current, to: nick, punctuation: punctuation)
        guard next != current else { return }
        textView.text = next
        textView.selectedRange = NSRange(location: (next as NSString).length, length: 0)
        textViewDidChange(textView)
    }

    /// Drop `text` in at the caret — how a finished upload's URL lands in the field (#14). A
    /// space is added before it when it would otherwise weld onto the preceding word, and one
    /// after it so the caret sits ready for a caption. The user then edits and sends: the
    /// upload produces a link, it doesn't send one, which keeps send-control where IRC wants
    /// it (a message is a URL plus whatever you say about it).
    ///
    /// `atCaret: false` appends at the end instead, and leaves the keyboard alone. That is for
    /// the *second and later* URLs of a multi-file upload, which arrive minutes apart while
    /// the user may well be typing the caption: splicing each one wherever the caret happens
    /// to be would cut their sentence in half, and taking first responder every time would
    /// shove the keyboard back up over a run they'd stopped watching.
    ///
    /// An append still carries the caret along **when it was sitting at the end** — which it
    /// is in the ordinary case, because that's where the previous insert left it. Pinning it
    /// there regardless meant every link after the first landed correctly while the caret
    /// stayed stranded behind the first one, so a caption typed afterwards would go in the
    /// wrong place. Only a caret the user has moved *into* the text is one they're using, and
    /// that is the only one worth protecting.
    func insert(_ text: String, atCaret: Bool = true) {
        let range = atCaret
            ? textView.selectedRange
            : NSRange(location: (textView.text as NSString).length, length: 0)
        let current = textView.text as NSString
        var payload = text
        if range.location > 0 {
            let prev = current.substring(with: NSRange(location: range.location - 1, length: 1))
            if let scalar = prev.unicodeScalars.first,
               !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                payload = " " + payload
            }
        }
        payload += " "
        // A caret resting at the end of the text isn't one the user is working at — it's just
        // where the last insert left it — so it rides along to the new end. Anywhere else, or
        // any live selection, is theirs and gets put back. `replaceToken` always drops the
        // caret past what it wrote, which is the "rides along" case already.
        let resumeAt = textView.selectedRange
        let caretWasTrailing = resumeAt.length == 0 && resumeAt.location >= current.length
        replaceToken(range, with: payload)
        if atCaret {
            becomeFirstResponder()
        } else if !caretWasTrailing, resumeAt.upperBound <= (textView.text as NSString).length {
            textView.selectedRange = resumeAt
        }
    }

    /// Swap `range` for `replacement` and drop the caret just past it. Programmatic edits
    /// don't fire the delegate, so this runs it by hand for the height, the send button, and
    /// the completion emit (now recomputed against the spliced text).
    private func replaceToken(_ range: NSRange, with replacement: String) {
        textView.text = (textView.text as NSString).replacingCharacters(in: range, with: replacement)
        textView.selectedRange = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        textViewDidChange(textView)
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool { textView.becomeFirstResponder() }

    @discardableResult
    override func resignFirstResponder() -> Bool { textView.resignFirstResponder() }

    // MARK: - Setup helpers

    /// One interactive glass effect. Interactive so it reacts to touch the way Messages'
    /// controls do — illuminating under the finger — and, inside the container, bleeding
    /// toward its neighbors as it does. An optional tint colors the glass; the send button
    /// takes the accent when it goes live.
    /// The container that groups the three pills into one glass system. Its `spacing` is the
    /// merge threshold — glass elements closer than it bleed toward each other. The default
    /// leaves them inert, so it's set well above the `gap` between the pills: they bridge
    /// with a glassy meniscus when touched rather than sitting in sealed panes, without
    /// fully fusing into one shape. This is the knob to turn — lower it if they merge too
    /// much, raise it if they don't bleed enough.
    private static func containerEffect() -> UIGlassContainerEffect {
        let effect = UIGlassContainerEffect()
        effect.spacing = 10
        return effect
    }

    private static func glass(tint: UIColor? = nil) -> UIGlassEffect {
        let glass = UIGlassEffect()
        glass.isInteractive = true
        glass.tintColor = tint
        return glass
    }

    /// A round glass pill wrapping a plain (non-glass) button — the button can't carry the
    /// glass itself and still join the container, so the glass is the wrapper and the button
    /// just fills it.
    private func configureRoundGlass(_ glass: UIVisualEffectView, button: UIButton, symbol: String) {
        glass.effect = Self.glass()
        glass.cornerConfiguration = .capsule()
        glass.translatesAutoresizingMaskIntoConstraints = false

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        config.preferredSymbolConfigurationForImage = Self.glyph
        config.baseForegroundColor = .label
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
        ])
    }

    // MARK: - State

    /// The send, by whichever key or button asked: the Send button, a hardware Enter
    /// (lurker-android#63), or the on-screen Return under "Enter to send" (lurker-android#64). One
    /// path, so one set of checks.
    private func fire() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend?(text)
    }

    /// A hardware Tab (Shift-Tab: `backward`) — the web composer's in-place completion
    /// (`TabCompletion`). Cycles the live completion while the field is as it left it; otherwise
    /// starts one from the word under the caret, and does nothing when nothing matches.
    ///
    /// An ordinary text change as far as the rest of the composer goes: the pill strip, the
    /// typing signal and the draft all hear it through `textViewDidChange`, as after a keystroke.
    private func tabComplete(backward: Bool) {
        // A selection has no caret to complete at: Tab is still taken, and changes nothing.
        guard textView.selectedRange.length == 0 else { return }
        // UTF-16, which is `TabCompletion`'s currency and `selectedRange`'s.
        let text = textView.text ?? ""
        let caret = textView.selectedRange.location
        let edit: TabCompletion.Edit
        if var session = tabCompletion, session.continues(text: text, caret: caret) {
            edit = session.cycle(backward: backward)
            tabCompletion = session
        } else if let source = tabSource?(),
                  let fresh = TabCompletion.begin(
                    text: text, caret: caret, nicks: source.nicks,
                    channels: source.channels, punctuation: source.punctuation) {
            edit = fresh.edit
            tabCompletion = fresh
        } else {
            tabCompletion = nil
            return
        }
        isApplyingTab = true
        defer { isApplyingTab = false }
        // Through `replace`, not `text =`: a programmatic set registers no undo, and a hardware
        // keyboard's Cmd-Z would then replay older typing ranges against the rewritten text.
        if let whole = textView.textRange(from: textView.beginningOfDocument, to: textView.endOfDocument) {
            textView.replace(whole, withText: edit.text)
        } else {
            textView.text = edit.text
        }
        textView.selectedRange = NSRange(location: edit.caret, length: 0)
        textViewDidChange(textView)
    }

    private func updateSendEnabled() {
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = hasText
        // Take the accent color when there's something to send, clear glass when not — the
        // same "lights up when it goes live" the Messages send button does, here through the
        // glass tint so it still belongs to the group. Only rebuilt on the transition:
        // reassigning `.effect` re-triggers the glass materialize, and this runs on every
        // keystroke.
        if sendActive != hasText {
            sendActive = hasText
            sendGlass.effect = Self.glass(tint: hasText ? .tintColor : nil)
            // White arrow on the accent tint when live, like Messages; back to `.label` on
            // the clear glass when there's nothing to send.
            sendButton.configuration?.baseForegroundColor = hasText ? .white : .label
        }
        placeholderLabel.isHidden = !textView.text.isEmpty
    }
}

extension ComposerBar: UITextViewDelegate {
    /// "Enter to send" (lurker-android#64): the on-screen keyboard's Return sends instead of
    /// starting a line. An empty draft sends nothing and gets no newline either — the key was a
    /// send.
    ///
    /// ⚠ A hardware Return never gets here: its key command has priority and consumes it
    /// (`ComposerTextView`). The one hardware `"\n"` that does is Shift-Enter's own insert, which
    /// is flagged so it stays a newline instead of sending. And were some keyboard ever to deliver
    /// a Return both ways, it still couldn't send twice: the owner clears the field inside
    /// `onSend`, so the second `fire()` finds it empty.
    ///
    /// ⚠ Never over marked text: Return there commits the IME's composition.
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard text == "\n", !isComposing, !self.textView.isInsertingHardwareNewline,
              // A pasted newline is pasted text, and dictation's "new line" is a line, not a send.
              !self.textView.isPasting, self.textView.textInputMode?.primaryLanguage != "dictation",
              UserPreferences.standard.composerEnterSends
        else { return true }
        fire()
        return false
    }

    /// Caret moves matter as much as keystrokes: arrowing out of a token (or into one)
    /// changes the completion context without changing the text.
    func textViewDidChangeSelection(_ textView: UITextView) {
        if !isApplyingTab { tabCompletion = nil }
        emitCompletion()
        // A commit that leaves the text as it was (romaji `ka` committed as typed) changes no
        // text, so `textViewDidChange` may not hear it — but the marked range went away. Asked
        // first, because this runs on every caret move and the full comparison copies the text.
        if isComposing != lastEdit.composing { reportEdit() }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        onEndEditing?()
    }

    /// Tell the owner the field changed, if it did. A restore is recorded without being told:
    /// the next real edit compares against what the field shows, not against an older text.
    private func reportEdit() {
        let now = (text: textView.text ?? "", composing: isComposing)
        guard now != lastEdit else { return }
        lastEdit = now
        if !isRestoring { onEdit?() }
    }

    /// Hand the owner the current completion context, only when it changed. A slash line is
    /// classified first (`CommandCompletion`); a channel/nick argument or the verb itself
    /// wins, and anything else — free text, an unknown command — falls through to nick
    /// detection, so `/me @al|` and `/me al|` still complete a nick. A selection (length > 0) is editing,
    /// never mid-token.
    private func emitCompletion() {
        let selection = textView.selectedRange
        let completion = activeCompletion(text: textView.text, caret: selection.location, isCollapsed: selection.length == 0)
        // Two optionals: the outer tracks "computed yet", the inner is the answer.
        guard lastCompletion == nil || lastCompletion! != completion else { return }
        lastCompletion = .some(completion)
        onCompletion?(completion)
    }

    private func activeCompletion(text: String, caret: Int, isCollapsed: Bool) -> Completion? {
        // A Tab completion owns the field while it cycles (see `tabCompletion`).
        guard isCollapsed, tabCompletion == nil else { return nil }
        if let context = CommandCompletion.context(in: text, caret: caret) {
            switch context {
            case .command(let query, _):
                return .command(query: query)
            case .argument(_, _, let kind, let query, _):
                return kind == .channel ? .channelArg(query: query) : .nickArg(query: query)
            }
        }
        // Not over marked text: a Pinyin or kana keyboard's unconverted letters are not a nick,
        // and a pick would replace them mid-composition.
        if !isComposing, let token = NickCompletion.activeMention(in: text, caret: caret) {
            return .mention(query: token.query)
        }
        return nil
    }

    func textViewDidChange(_ textView: UITextView) {
        if !isApplyingTab { tabCompletion = nil }
        updateSendEnabled()
        if !isRestoring { emitCompletion() }
        // Only when the text genuinely differs. This method is also called by hand for
        // *layout* reasons — `updateMetrics()` on a Dynamic Type change, which re-measures the
        // field without touching a character — and firing the draft hook there would tell the
        // channel you'd resumed typing because you changed your text size in Control Center.
        let draft = textView.text ?? ""
        if !isRestoring, draft != lastEmittedDraft {
            lastEmittedDraft = draft
            onDraftChange?(draft)
        }
        reportEdit()

        // Grow to fit the text, up to the cap; past it, hold the height and let the text
        // scroll inside. The floor is one line's height, the same value the pills use, so a
        // one-line message is exactly as tall as the empty field.
        let fitting = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        ).height
        let lineHeight = ceil((textView.font ?? .preferredFont(forTextStyle: .body)).lineHeight)
        let cap = Self.collapsedHeight + CGFloat(Self.maxLines - 1) * lineHeight
        let target = min(max(fitting, Self.collapsedHeight), cap)
        textView.isScrollEnabled = fitting > cap
        guard abs(textHeight.constant - target) > 0.5 else { return }
        textHeight.constant = target
        onHeightChange?()
    }
}
