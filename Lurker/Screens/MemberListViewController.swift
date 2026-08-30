// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// The nick list, summoned by a swipe in from the right edge.
///
/// Shows who's here, ranked, with away state; a row opens that person's profile (#12). It was
/// a placeholder until there was somewhere for a row to go — the list itself was finished, and
/// what made it a placeholder was `selectionStyle = .none`.
///
/// A search field appears once the channel is big enough to need one. Filtering is on the nick
/// only, not on the rank glyph: `@` is a fact about the row, not part of the name, and matching
/// it would make searching for a literal `@` return every operator.
///
/// The list is live (#30): the store folds join/part/quit/kick/nick into
/// `ChatState.members` and applies the server's `names`/`member-update` broadcasts, so
/// what renders here tracks the channel, not the last connect. This view just observes.
final class MemberListViewController: UITableViewController {
    private let viewModel: ChatViewModel
    private let buffer: Buffer
    private var cancellables = Set<AnyCancellable>()

    /// Everyone in the channel, ranked. The table draws `visible`, which is this filtered by
    /// the search field.
    private var members: [Member] = []
    private var visible: [Member] = []

    /// Below this, the field is clutter: every nick already fits on a screen or two, and
    /// scrolling finds them faster than typing does. Above it, scanning stops working.
    private static let searchThreshold = 20

    /// Passed through to the profile a row opens, for its Send Message and channel rows.
    ///
    /// Handed back for the same reason `BufferInfoViewController` hands its rows back: this
    /// screen is inside a sheet, and the presenter owns what happens to that sheet. Nil means
    /// the profile simply doesn't offer those rows — see `UserProfileViewController`.
    var onOpenBuffer: ((BufferKey) -> Void)?

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
        // The field appears and disappears with the channel's size, so a room that empties out
        // below the threshold stops offering one. Assigned only on change: reassigning
        // `searchController` mid-edit dismisses the keyboard.
        let wantsSearch = members.count >= Self.searchThreshold
        if wantsSearch != (navigationItem.searchController != nil) {
            // ⚠⚠ Clear the field BEFORE detaching it. `refilter` reads the search bar whether
            // or not it is on screen, so a netsplit that drops a filtered channel under the
            // threshold would take the field away and leave the list filtered to a query with
            // nothing left to clear it — possibly to "No members match." over a populated
            // channel. (Detaching a controller that is still `isActive` is not a state UIKit
            // handles gracefully either.)
            if !wantsSearch {
                searchController.isActive = false
                searchController.searchBar.text = ""
            }
            navigationItem.searchController = wantsSearch ? searchController : nil
        }
        refilter()
    }

    /// Narrow to what the field asks for, and say so when nothing matches.
    ///
    /// Case-insensitive substring rather than prefix: you rarely remember which end of a nick
    /// you know, and a nicklist is short enough that the looser match costs nothing.
    private func refilter() {
        let query = (searchController.searchBar.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        visible = query.isEmpty
            ? members
            : members.filter { $0.nick.lowercased().contains(query) }
        tableView.backgroundView = visible.isEmpty ? emptyLabel : nil
        if visible.isEmpty { emptyLabel.text = emptyText(searching: !query.isEmpty) }
        tableView.reloadData()
    }

    private lazy var searchController: UISearchController = {
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        // The nicklist stays put and filters in place — there is no second results screen to
        // dim toward, and dimming the very list being filtered hides the answer.
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Filter members"
        search.searchBar.autocapitalizationType = .none
        search.searchBar.autocorrectionType = .no
        search.searchBar.spellCheckingType = .no
        return search
    }()

    /// Says which of the two reasons the list is empty, because they need different things
    /// from the user: a DM has nobody to list and never will, while a channel with no
    /// members means we haven't been told yet.
    ///
    /// Built once — the text depends only on this screen's buffer, and `apply` runs on
    /// every state change that reaches us.
    private lazy var emptyLabel: UILabel = {
        let label = UILabel()
        label.text = emptyText(searching: false)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    /// A filter that matched nothing is a different fact from a channel with nobody in it, and
    /// the two need different things from the reader — one is "type less", the other is "wait".
    private func emptyText(searching: Bool) -> String {
        if searching { return "No members match." }
        switch buffer.kind {
        case .channel: return "No members yet."
        case .dm: return "Direct messages have no member list."
        case .server, .system: return "This buffer has no member list."
        }
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        visible.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "member", for: indexPath)
        let member = visible[indexPath.row]
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
        return cell
    }

    /// A row opens that person's profile (#12) — whois, their note, and the way to DM them.
    ///
    /// This is the tap the list was missing. Pushed onto the sheet's own navigation controller
    /// rather than presented, so the profile arrives *inside* the nicklist sheet and Back
    /// returns to the list you were scanning — one sheet, two depths, which is also what keeps
    /// it clear of the chat screen's one-sheet-at-a-time rule.
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let networkId = buffer.networkId, indexPath.row < visible.count else { return }
        let profile = UserProfileViewController(
            viewModel: viewModel, networkId: networkId, nick: visible[indexPath.row].nick
        )
        profile.onOpenBuffer = onOpenBuffer
        navigationController?.pushViewController(profile, animated: true)
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
        guard let networkId = buffer.networkId, indexPath.row < visible.count else { return nil }
        let nick = visible[indexPath.row].nick
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

extension MemberListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        refilter()
    }
}
