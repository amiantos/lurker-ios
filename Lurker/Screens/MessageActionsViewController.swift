// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// What you can do with one message, as a bottom sheet (#60) — the Discord shape rather than the
/// iMessage one.
///
/// A `UIContextMenuInteraction` was the first attempt and this screen defeats it. Lifting just the
/// bubble is only expressible as `UITargetedPreview(view:)`, which hands UIKit a *live* subview of
/// a reusable cell — and the message list calls `reloadData()` on every apply, so a message
/// arriving mid-press recycled the cell UIKit was holding. Falling back to UIKit's own preview
/// fixed that by lifting the whole row, which on a phone is a full-width card for a three-word
/// message. Both were wrong, and both were wrong for the same reason: a peek is a picture *of the
/// list*, so it's coupled to how the list happens to draw itself.
///
/// A sheet is presented over the list instead of lifted out of it. Nothing the table does
/// underneath can reach it, and it says nothing about how a row is drawn — so the second
/// message-list style inherits these actions unchanged, which is the point of building this before
/// the styles land.
///
/// The subject is named at the top. That isn't decoration: the peek it replaces was the only thing
/// confirming *which* line you pressed, and a menu that can act on the wrong message without
/// showing you is worse than one that's a bit taller.
final class MessageActionsViewController: UITableViewController {

    /// Run this action. The sheet is already dismissed by the time it fires — Reply raises the
    /// keyboard, which can't happen underneath a sheet that's still on screen.
    var onRun: ((MessageActionKey) -> Void)?

    /// What the sheet is about. A press that lands on a link is about the link — the line around
    /// it isn't what you were pointing at — which is the same split Discord makes.
    enum Subject {
        /// The line, plus the facts about where it lives that the line itself doesn't carry —
        /// see `MessageActionScope`.
        case message(Message, scope: MessageActionScope)
        case link(URL)
    }

    private let subject: Subject
    private let actions: [MessageAction]
    /// Rows stay tappable through the dismissal animation, so without this a quick double tap on
    /// Share Link queues two runs — and the second `UIActivityViewController` is dropped by UIKit
    /// with a console warning rather than presented.
    private var hasRun = false
    /// The content height the sheet was last sized to, so a re-layout that changed nothing doesn't
    /// invalidate the detent.
    private var measuredHeight: CGFloat = 0

    private static let detent = UISheetPresentationController.Detent.Identifier("messageActions")
    /// Only for the pre-layout estimate above; the real heights are self-sizing.
    private static let estimatedRowHeight: CGFloat = 52
    private static let estimatedHeaderHeight: CGFloat = 88

    /// Nil when the subject offers nothing — the caller shouldn't present an empty sheet.
    init?(subject: Subject) {
        let actions: [MessageAction] = switch subject {
        case .message(let message, let scope): MessageActions.build(for: message, scope: scope)
        case .link(let url): MessageActions.build(for: url)
        }
        guard !actions.isEmpty else { return nil }
        self.subject = subject
        self.actions = actions
        // Seeded, not left at zero: the detent is resolved once before the first layout, so an
        // unseeded sheet animates in as a ~40pt sliver and then jumps to its real height. The
        // estimate is replaced by the measured value on the first `viewDidLayoutSubviews`.
        self.measuredHeight = Self.estimatedHeaderHeight + CGFloat(actions.count) * Self.estimatedRowHeight
        super.init(style: .insetGrouped)

        modalPresentationStyle = .pageSheet
        sheetPresentationController?.prefersGrabberVisible = true
        // Sized to its rows rather than `.medium()`: two actions in a half-screen sheet is mostly
        // empty space, and the conversation behind it is what you're acting on — worth leaving
        // visible. Capped at the maximum so a long quoted message can't outgrow the screen.
        sheetPresentationController?.detents = [
            .custom(identifier: Self.detent) { [weak self] context in
                guard let self else { return context.maximumDetentValue }
                return min(preferredHeight, context.maximumDetentValue)
            }
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "action")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = Self.estimatedRowHeight
        tableView.alwaysBounceVertical = false
        // The subject is a header, not a row: as a cell it sat in its own rounded card, indented
        // and left-aligned exactly like the actions under it, so it read as a fourth thing you
        // could tap. It also let `insetGrouped` put a section gap between the two, which is the
        // slack that made the sheet look loose.
        tableView.tableHeaderView = makeHeader()
        // No empty strip above the one remaining section.
        tableView.sectionHeaderTopPadding = 0
    }

    /// Title over detail, centered, above the actions — the shape a share sheet uses, because this
    /// is the same kind of object: a thing, then what you can do to it.
    private func makeHeader() -> UIView {
        let title = UILabel()
        title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center
        title.numberOfLines = 1
        title.lineBreakMode = .byTruncatingTail

        let detail = UILabel()
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .secondaryLabel
        detail.textAlignment = .center
        detail.numberOfLines = 3

        switch subject {
        case .message(let message, _):
            // The nick names who you're acting on; the body confirms which of their lines it was.
            //
            // Stripped of mIRC codes, deliberately unlike Copy Text, which keeps them. The header's
            // only job is identification, so it has to match what's on screen: raw,
            // `\u{03}04ALERT\u{03} disk full` reads as red "ALERT disk full" in the list but as
            // "04ALERT disk full" here — the one case where the header would show a different line
            // from the one pressed. Copy keeps the codes because the pasteboard is about fidelity
            // to what was sent, which is also what the web does.
            //
            // A re-attributed relay line (#277) names its bridge here: "alice via relaybot". This
            // sheet is the whole of that provenance on iOS — the web puts it in a `title=` tooltip
            // on the `[source]` tag, and a phone has no hover to put it behind. It belongs on the
            // title rather than in a row of its own because it qualifies *who you are acting on*:
            // Reply and Copy target alice, and the only thing here with an IRC presence is the bot.
            let speaker = (message.nick?.isEmpty == false) ? message.nick! : "Message"
            title.text = message.relayBot.map { "\(speaker) via \($0)" } ?? speaker
            detail.text = message.text.map { IRCFormatting.strip($0) }
        case .link(let url):
            // Host as the title: "which site is this" is the question a link menu has to answer
            // first, and it stays legible where a long URL truncates to nothing useful.
            title.text = url.host ?? "Link"
            detail.text = url.absoluteString
        }

        let stack = UIStackView(arrangedSubviews: [title, detail])
        stack.axis = .vertical
        // The title needs to clear the grabber rather than sit just under it, and the detail needs
        // to read as a caption *of* the title rather than a second line of it — at 2pt the two ran
        // together as one block.
        stack.spacing = 6
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 26, leading: 32, bottom: 14, trailing: 32)
        return stack
    }

    /// A `tableHeaderView` does not self-size; without this it takes whatever height it was given
    /// (zero), and the header is invisible.
    private func sizeHeader() {
        guard let header = tableView.tableHeaderView else { return }
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        guard abs(header.frame.height - height) > 0.5 || abs(header.frame.width - width) > 0.5 else { return }
        header.frame = CGRect(x: 0, y: 0, width: width, height: height)
        tableView.tableHeaderView = header // reassignment is what commits the new height
    }

    /// Re-size once the rows have actually been laid out. `contentSize` is estimated until then,
    /// so the detent built in `init` would otherwise be sized off a guess — a multi-line quote
    /// would be clipped.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeHeader()
        let height = tableView.contentSize.height
        guard abs(height - measuredHeight) > 0.5 else { return }
        measuredHeight = height
        sheetPresentationController?.animateChanges {
            sheetPresentationController?.invalidateDetents()
        }
    }

    private var preferredHeight: CGFloat {
        // The grabber's strip plus the home indicator's, neither of which is in `contentSize`.
        measuredHeight + view.safeAreaInsets.bottom + 24
    }

    // MARK: - Rows

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        actions.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "action", for: indexPath)
        let action = actions[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = action.title
        content.image = UIImage(systemName: action.symbol)
        // Taller than a settings row: this is a short list of deliberate choices under a thumb,
        // not a dense table to scan.
        content.directionalLayoutMargins.top = 14
        content.directionalLayoutMargins.bottom = 14
        content.imageToTextPadding = 14
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !hasRun else { return }
        hasRun = true
        let key = actions[indexPath.row].key
        // Dismiss first, act second. Reply hands focus to the composer, and a `becomeFirstResponder`
        // issued from under a sheet that is still on screen doesn't take — you'd get `nick: ` in the
        // field and no keyboard.
        dismiss(animated: true) { [weak self] in self?.onRun?(key) }
    }
}
