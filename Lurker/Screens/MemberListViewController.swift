// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// The nick list, summoned by a swipe in from the right edge.
///
/// Deliberately a placeholder for the real member list (#12): it shows who's here, ranked,
/// with away state — and nothing else. No whois, no per-member actions.
///
/// The list is live (#30): the store folds join/part/quit/kick/nick into
/// `ChatState.members` and applies the server's `names`/`member-update` broadcasts, so
/// what renders here tracks the channel, not the last connect. This view just observes.
final class MemberListViewController: UITableViewController {
    private let viewModel: ChatViewModel
    private let buffer: Buffer
    private var cancellables = Set<AnyCancellable>()

    private var members: [Member] = []

    init(viewModel: ChatViewModel, buffer: Buffer) {
        self.viewModel = viewModel
        self.buffer = buffer
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "member")

        // A row with a colored mode glyph bakes its font into an attributed string, which puts
        // it outside `textProperties.adjustsFontForContentSizeCategory` — the flag can only
        // rescale a font the configuration owns. Rebuilding the rows is what carries a text-size
        // change through instead, since `cellForRowAt` re-reads the font every time.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (list: Self, _) in
            list.tableView.reloadData()
        }

        let key = buffer.key.id
        viewModel.statePublisher
            // The ignore set decides who's *listed*, not just who's in the room, so a rule
            // arriving from another device has to wake this screen the same way a join does.
            // (`===` is the right test — see `IgnoreSet`.)
            .removeDuplicates { $0.members[key] == $1.members[key] && $0.ignores === $1.ignores }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &cancellables)
        apply(viewModel.state)
    }

    private func apply(_ state: ChatState) {
        members = MemberPrefix.sorted(state.visibleMembers(in: buffer.key))
        title = members.isEmpty ? "Members" : "Members (\(members.count))"
        tableView.backgroundView = members.isEmpty ? emptyLabel : nil
        tableView.reloadData()
    }

    /// Says which of the two reasons the list is empty, because they need different things
    /// from the user: a DM has nobody to list and never will, while a channel with no
    /// members means we haven't been told yet.
    ///
    /// Built once — the text depends only on this screen's buffer, and `apply` runs on
    /// every state change that reaches us.
    private lazy var emptyLabel: UILabel = {
        let label = UILabel()
        switch buffer.kind {
        case .channel: label.text = "No members yet."
        case .dm: label.text = "Direct messages have no member list."
        case .server, .system: label.text = "This buffer has no member list."
        }
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        members.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "member", for: indexPath)
        let member = members[indexPath.row]
        var content = UIListContentConfiguration.cell()
        let prefix = MemberPrefix.of(member.modes)
        // Away members stay in place rather than sorting to the bottom — you look for a
        // nick where you last saw it — and are dimmed instead.
        let base: UIColor = member.away ? .tertiaryLabel : .label
        content.text = prefix + member.nick
        content.textProperties.color = base

        // The mode glyph wears its rank's color (`look.color.member.*`), the nick does not —
        // the same split the web client makes, and the reason ranks are scannable without
        // reading: five fixed colors in a fixed order down the leading edge.
        //
        // Not for an away member, though. There the whole row goes flat, glyph included, so it
        // reads as inert — a bright `@` beside a greyed-out nick says the wrong thing about who
        // is actually around to use it. (The web's `li.away` rule overrides its prefix color for
        // exactly this.)
        if !member.away, let rank = Palette.memberPrefix(prefix) {
            // ⚠ `attributedText` "supersedes the text and some properties of the textProperties"
            // (UIListContentConfiguration.h) — which properties is not spelled out, so nothing is
            // left to `textProperties` here: the font and the base color are both written onto
            // the string, and only then is the glyph's range restyled.
            //
            // ⚠ The font is built from this controller's traits, NOT read off
            // `content.textProperties.font`. That property is still the configuration's
            // *unresolved* default at this point — UIKit resolves it in `updated(for:)`, after
            // assignment — so a row taking this branch could end up a size away from the plain
            // rows beside it. Passing traits explicitly is the same rule `MessageRenderer`
            // follows for every font it builds, and for the same reason.
            let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
            let attributed = NSMutableAttributedString(
                string: content.text ?? "",
                attributes: [.foregroundColor: base, .font: font]
            )
            // Bold, and not only for emphasis. These five hues are specified against the message
            // list's `Palette.bg`; an inset-grouped cell is `.secondarySystemGroupedBackground`,
            // which is pure white in light mode, and four of the five land between 3.4:1 and
            // 4.0:1 there — under the 4.5:1 that regular-weight body text is held to. Bold at
            // this size is WCAG "large text", whose bar is 3:1 and which all five clear, and a
            // heavier glyph is genuinely easier to pick out at one character wide besides.
            attributed.addAttributes(
                [.foregroundColor: rank, .font: font.bold],
                range: NSRange(location: 0, length: prefix.utf16.count)
            )
            content.attributedText = attributed
        }
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    /// Long-press a member to add them to Friends — straight off a nick you're looking at
    /// (the web client's member menu does the same). A friend is just a favorited DM now:
    /// open-buffer first mints/reopens the DM row (the server refuses favoriting a buffer
    /// that doesn't exist or is closed), and the same socket delivers it before the
    /// favorite, so the pair can't race. No navigation — the DM appears under Friends.
    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let networkId = buffer.networkId, indexPath.row < members.count else { return nil }
        let nick = members[indexPath.row].nick
        let isFriend = viewModel.state.isFavorite(BufferKey(networkId: networkId, target: nick))
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                isFriend
                    ? UIAction(
                        title: "Remove from Friends",
                        image: UIImage(systemName: "person.badge.minus"),
                        attributes: .destructive
                    ) { _ in
                        self?.viewModel.unfavoriteBuffer(networkId: networkId, target: nick)
                    }
                    : UIAction(title: "Add to Friends", image: UIImage(systemName: "person.badge.plus")) { _ in
                        guard let self else { return }
                        self.viewModel.openBuffer(BufferKey(networkId: networkId, target: nick))
                        self.viewModel.favoriteBuffer(networkId: networkId, target: nick)
                    },
            ])
        }
    }
}
