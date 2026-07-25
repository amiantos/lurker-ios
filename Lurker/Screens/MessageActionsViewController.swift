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
        case message(Message)
        case link(URL)
    }

    private let subject: Subject
    private let actions: [MessageAction]
    /// The content height the sheet was last sized to, so a re-layout that changed nothing doesn't
    /// invalidate the detent.
    private var measuredHeight: CGFloat = 0

    private static let detent = UISheetPresentationController.Detent.Identifier("messageActions")

    /// Nil when the subject offers nothing — the caller shouldn't present an empty sheet.
    init?(subject: Subject) {
        let actions: [MessageAction] = switch subject {
        case .message(let message): MessageActions.build(for: message)
        case .link(let url): MessageActions.build(for: url)
        }
        guard !actions.isEmpty else { return nil }
        self.subject = subject
        self.actions = actions
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
        tableView.estimatedRowHeight = 52
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
        case .message(let message):
            // The nick names who you're acting on; the body confirms which of their lines it was.
            // Raw text, matching what Copy would put on the pasteboard — a sheet that shows one
            // thing and copies another is worse than one that shows nothing.
            title.text = (message.nick?.isEmpty == false) ? message.nick : "Message"
            detail.text = message.text
        case .link(let url):
            // Host as the title: "which site is this" is the question a link menu has to answer
            // first, and it stays legible where a long URL truncates to nothing useful.
            title.text = url.host ?? "Link"
            detail.text = url.absoluteString
        }

        let stack = UIStackView(arrangedSubviews: [title, detail])
        stack.axis = .vertical
        stack.spacing = 2
        stack.isLayoutMarginsRelativeArrangement = true
        // Tight to the grabber above, with air before the actions below.
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 32, bottom: 14, trailing: 32)
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
        let key = actions[indexPath.row].key
        // Dismiss first, act second. Reply hands focus to the composer, and a `becomeFirstResponder`
        // issued from under a sheet that is still on screen doesn't take — you'd get `nick: ` in the
        // field and no keyboard.
        dismiss(animated: true) { [weak self] in self?.onRun?(key) }
    }
}
