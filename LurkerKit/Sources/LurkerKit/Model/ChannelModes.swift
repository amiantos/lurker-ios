// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A network's channel-mode vocabulary, as the server parsed it from ISUPPORT (lurker#727,
/// `shared/channelModes.ts`). The client never reads 005 itself: everything a mode control,
/// a rank gate or a MODE line needs is in this one shape.
///
/// ⚠⚠ `Network.modeSpec` is **nil until the network's registration burst has ended**, and nil
/// means "unknown", never the RFC defaults. Before the burst the server only has defaults, and
/// a default is not the network saying so.
///
/// ⚠ `q` is the classic trap: a quiet LIST mode on solanum, an owner PREFIX on InspIRCd and
/// Unreal. Nothing here hardcodes it; which group a letter sits in is the server's answer.
public struct ModeSpec: Equatable, Sendable {
    /// CHANMODES group A — list modes: bans, exceptions, invite exceptions, quiets.
    public let list: String
    /// Group B — always take a param (`k`).
    public let always: String
    /// Group C — take a param only when set (`l`).
    public let onSet: String
    /// Group D — plain flags.
    public let flags: String
    /// Membership modes, highest rank first.
    public let prefix: [PrefixMode]
    /// How many param-taking changes one MODE line may carry; nil is no limit.
    public let maxModes: Int?
    /// The longest topic the server accepts, in BYTES; nil when not advertised.
    public let topicLen: Int?

    public init(
        list: String, always: String, onSet: String, flags: String,
        prefix: [PrefixMode], maxModes: Int?, topicLen: Int?
    ) {
        self.list = list
        self.always = always
        self.onSet = onSet
        self.flags = flags
        self.prefix = prefix
        self.maxModes = maxModes
        self.topicLen = topicLen
    }

    /// The conventional ladder, for a gate asked before the network has said (`modeSpec` nil).
    /// Only ever used to *gate* — never to classify a letter, which needs the real spec.
    public static let defaultPrefix: [PrefixMode] = [
        PrefixMode(mode: "q", symbol: "~"), PrefixMode(mode: "a", symbol: "&"),
        PrefixMode(mode: "o", symbol: "@"), PrefixMode(mode: "h", symbol: "%"),
        PrefixMode(mode: "v", symbol: "+"),
    ]
}

/// One membership mode from PREFIX, e.g. `o` / `@`.
public struct PrefixMode: Equatable, Sendable {
    public let mode: String
    public let symbol: String

    public init(mode: String, symbol: String) {
        self.mode = mode
        self.symbol = symbol
    }
}

/// Ranking members by the network's own PREFIX — the port of `rankIndex` / `hasRankAtLeast`.
public enum ChannelRank {
    /// The conventional ladder, used only to pick a stand-in when a gate names a letter the
    /// network doesn't have.
    private static let conventional = ["q", "a", "o", "h", "v"]

    /// Where a member's highest mode sits in PREFIX order: 0 for the top rank, nil when they
    /// hold none. Scans by rank, never by array position.
    public static func index(_ modes: [String], prefix: [PrefixMode]) -> Int? {
        prefix.firstIndex { modes.contains($0.mode) }
    }

    /// Whether a member ranks at or above `letter` (`"o"` for "op or higher").
    ///
    /// When the network has no `letter`, the gate moves UP the conventional ladder to the next
    /// letter it does have — a network without halfops asks "op or higher" of a halfop gate.
    /// Rounding up is the direction that can't hand out a control the server will refuse.
    public static func atLeast(_ modes: [String], prefix: [PrefixMode], _ letter: String) -> Bool {
        guard let held = index(modes, prefix: prefix) else { return false }
        var threshold = prefix.firstIndex { $0.mode == letter }
        if threshold == nil, let start = conventional.firstIndex(of: letter) {
            for candidate in conventional[..<start].reversed() {
                threshold = prefix.firstIndex { $0.mode == candidate }
                if threshold != nil { break }
            }
        }
        guard let threshold else { return false }
        return held <= threshold
    }
}

/// A channel's mode and topic metadata, as the server last stated it — a side table on
/// `ChatState` beside `members`, keyed the same way.
///
/// ⚠⚠ **Never carries the key.** `modes` has the letter `k` and nothing else: the value lives
/// only in the network config (`GET /api/networks` → `channels[].key`) and on the `mode` row
/// that set it.
public struct ChannelModeState: Equatable, Sendable {
    /// Every set letter, e.g. `"ntkl"`.
    public var modes: String
    /// The values of set param modes, e.g. `["l": "50"]`.
    public var params: [String: String]
    /// When the channel was created (329), when the server has said.
    public var createdAt: Date?
    /// Who last set the topic and when (333, or a live TOPIC). Either may be nil: a 333 can
    /// carry the time alone.
    public var topicSetBy: String?
    public var topicSetAt: Date?

    public init(
        modes: String = "", params: [String: String] = [:], createdAt: Date? = nil,
        topicSetBy: String? = nil, topicSetAt: Date? = nil
    ) {
        self.modes = modes
        self.params = params
        self.createdAt = createdAt
        self.topicSetBy = topicSetBy
        self.topicSetAt = topicSetAt
    }
}

extension ChannelModeState {
    /// "Set by alice · 1 Sep 2026 at 10:00" — whatever of the two the server said, or nil.
    public var topicSetterLine: String? {
        let nick = topicSetBy.map(ChannelModeForm.setterNick)
        let when = topicSetAt?.formatted(date: .abbreviated, time: .shortened)
        switch (nick, when) {
        case let (nick?, when?): return "Set by \(nick) · \(when)"
        case let (nick?, nil): return "Set by \(nick)"
        case let (nil, when?): return "Set \(when)"
        case (nil, nil): return nil
        }
    }
}

/// One entry of a list mode — a ban, exception, invite exception or quiet.
public struct ModeListEntry: Equatable, Sendable {
    public let mask: String
    public let setBy: String?
    public let setAt: Date?

    public init(mask: String, setBy: String?, setAt: Date?) {
        self.mask = mask
        self.setBy = setBy
        self.setAt = setAt
    }
}

/// The answer to `get-mode-list`.
public enum ModeListResult: Equatable, Sendable {
    case entries([ModeListEntry])
    /// The network isn't connected (or our socket dropped under the ask) — worth asking again
    /// once it is, unlike a refusal.
    case offline
    /// Why there's no list, worded for the screen.
    case failed(String)
}

/// The channel's `error` rows read as the answer to a change this screen just sent.
///
/// ⚠ By timing, because nothing better exists: MODE changes are untracked by the server's reply
/// router (a no-op change gets no reply, so there's no reliable end to wait for), so a refusal —
/// 482, 467, 478 — arrives as the channel's `error` row with nothing tying it to the change. The
/// rows that land soon after a send are taken as its answer; a server answers a MODE in moments,
/// and an unrelated error minutes later is not this change's. The web modal draws the same line.
public struct ChannelRefusals: Equatable, Sendable {
    private var seen: [(text: String, at: Date)] = []
    private var armed: (from: Int, at: Date)?
    public static let window: TimeInterval = 10

    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.current == rhs.current }

    /// A change just went out: errors from here on are its answer.
    public mutating func arm(at now: Date = Date()) { armed = (seen.count, now) }

    /// An `error` row for this channel arrived.
    public mutating func note(_ text: String, at now: Date = Date()) { seen.append((text, now)) }

    /// The errors answering the latest change — those inside the window after it was sent.
    public var current: [String] {
        guard let armed, armed.from <= seen.count else { return [] }
        return seen[armed.from...].filter { $0.at.timeIntervalSince(armed.at) < Self.window }.map(\.text)
    }
}

/// One MODE change to send — `param` present exactly when the mode takes one in that direction.
public struct OutgoingModeChange: Equatable, Sendable {
    public let sign: Character
    public let letter: String
    public let param: String?

    public init(sign: Character, letter: String, param: String? = nil) {
        self.sign = sign
        self.letter = letter
        self.param = param
    }
}

/// The channel-settings form as pure functions — the port of the web's `channelModeForm.ts`
/// and `modeListPatch.ts`. Which rows to draw from the spec, what MODE changes an edit amounts
/// to, and how a fetched list stays current.
public enum ChannelModeForm {
    /// The names a letter has on every ircd we know. Anything else shows as `+X` — a
    /// hand-written table that guesses is how gamja came to describe `+n` backwards.
    private static let names: [String: String] = [
        "n": "No outside messages",
        "t": "Only operators set the topic",
        "i": "Invite only",
        "m": "Moderated",
        "s": "Secret",
        "p": "Private",
        "k": "Key",
        "l": "User limit",
    ]

    /// The list modes the server can fetch, in the order they're offered, with their names.
    /// Only these: the server's reply router knows the numerics of nothing else.
    public static let lists: [(letter: String, name: String)] = [
        ("b", "Bans"), ("e", "Exceptions"), ("I", "Invite Exceptions"), ("q", "Quiets"),
    ]

    public static func name(of letter: String) -> String? { names[letter] }

    /// The nick out of a setter as the server names one: a 333 or a list entry often carries the
    /// full `nick!user@host`, which is noise on a phone-width line.
    public static func setterNick(_ setter: String) -> String {
        String(setter.split(separator: "!", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(setter))
    }

    /// The fetchable lists this network has, in display order.
    public static func lists(in spec: ModeSpec) -> [(letter: String, name: String)] {
        lists.filter { spec.list.contains($0.letter) }
    }

    public enum RowKind: Equatable, Sendable {
        case flag
        case param
        case key
    }

    public struct Row: Equatable, Sendable {
        public let letter: String
        public let kind: RowKind
        public let name: String?
    }

    /// Every flag and param mode the network advertises, the well-known ones first. List modes
    /// have their own screens, and prefix modes are people, not the channel.
    public static func rows(_ spec: ModeSpec) -> [Row] {
        var out: [Row] = []
        for letter in spec.flags.map(String.init) {
            out.append(Row(letter: letter, kind: .flag, name: name(of: letter)))
        }
        for letter in (spec.always + spec.onSet).map(String.init) {
            out.append(Row(letter: letter, kind: letter == "k" ? .key : .param, name: name(of: letter)))
        }
        // Stable: the network's own order within each half.
        return out.filter { $0.name != nil } + out.filter { $0.name == nil }
    }

    /// One row as the user left it, or as the channel has it.
    public struct DraftRow: Equatable, Sendable {
        public var on: Bool
        public var value: String

        public init(on: Bool, value: String) {
            self.on = on
            self.value = value
        }
    }

    /// The channel's modes as the form diffs against them.
    public struct Live: Equatable, Sendable {
        /// Every set letter.
        public var modes: String
        /// Values of set param modes. The server never sends the key; the screen puts the one
        /// it knows here while the channel is `+k`, so an untouched key field reads as "keep".
        public var params: [String: String]

        public init(modes: String, params: [String: String]) {
            self.modes = modes
            self.params = params
        }

        public func row(_ letter: String) -> DraftRow {
            DraftRow(on: modes.contains(letter), value: params[letter] ?? "")
        }
    }

    /// The MODE changes that turn the live state into the draft, or the first problem that
    /// stops it. Rows the draft left alone are not looked at.
    public static func changes(
        spec: ModeSpec, live: Live, draft: [String: DraftRow]
    ) -> Result<[OutgoingModeChange], ChangeError> {
        var out: [OutgoingModeChange] = []
        let kinds = Dictionary(rows(spec).map { ($0.letter, $0.kind) }, uniquingKeysWith: { a, _ in a })
        // Sorted, so the same draft always makes the same lines.
        for letter in draft.keys.sorted() {
            guard let want = draft[letter], let kind = kinds[letter] else { continue }
            let was = live.row(letter)
            let value = want.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if kind == .flag {
                if want.on != was.on { out.append(OutgoingModeChange(sign: want.on ? "+" : "-", letter: letter)) }
                continue
            }
            if !want.on {
                guard was.on else { continue }
                // A B-group mode names its value to unset it (`*` when we never learned it);
                // the server fills in -k's.
                let needsParam = spec.always.contains(letter) && kind != .key
                out.append(OutgoingModeChange(
                    sign: "-", letter: letter, param: needsParam ? (was.value.isEmpty ? "*" : was.value) : nil
                ))
                continue
            }
            // Only now: a value being turned off doesn't need to be a valid one.
            if value.contains(where: \.isWhitespace) { return .failure(.spaces(letter)) }
            if kind == .key {
                if value.isEmpty {
                    if !was.on { return .failure(.keyRequired) }
                    continue // on, and no new key: keep the one it has
                }
                if was.on, value == was.value { continue }
                // Replacing a key: several ircds answer a bare +k over an existing one with
                // 467, so take the old one off first.
                if was.on { out.append(OutgoingModeChange(sign: "-", letter: letter)) }
                out.append(OutgoingModeChange(sign: "+", letter: letter, param: value))
                continue
            }
            if value.isEmpty { return .failure(.valueRequired(letter)) }
            if !was.on || value != was.value {
                out.append(OutgoingModeChange(sign: "+", letter: letter, param: value))
            }
        }
        return .success(out)
    }

    public enum ChangeError: Error, Equatable, Sendable {
        case spaces(String)
        case keyRequired
        case valueRequired(String)

        public var message: String {
            switch self {
            case .spaces(let letter): "+\(letter) can't contain spaces."
            case .keyRequired: "Enter a key."
            case .valueRequired(let letter): "Enter a value for +\(letter)."
            }
        }
    }

    /// A topic's length as the server counts it: bytes, not characters.
    public static func topicBytes(_ topic: String) -> Int { topic.utf8.count }

    /// A topic is one line on the wire; a pasted newline becomes a space.
    public static func topicToSend(_ text: String) -> String {
        text.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
    }

    /// The channel's key as the newest `±k` in `rows` says: a `+k <key>` names it, a `-k` means
    /// there is none (so a key the config still remembers doesn't come back). `*` is a mask,
    /// not a key. `.none` — no ±k seen at all — leaves the config's copy standing.
    public static func lastKeyChange(_ rows: [Message]) -> KeySighting {
        for row in rows.reversed() {
            for change in row.modes.reversed() {
                if change.mode == "-k" { return .removed }
                if change.mode == "+k", let param = change.param, !param.isEmpty, param != "*" {
                    return .set(param)
                }
            }
        }
        return .none
    }

    public enum KeySighting: Equatable, Sendable {
        case none
        case removed
        case set(String)
    }

    /// `entries` with every ±`letter` list change in `rows` applied, in order. Masks match
    /// case-insensitively, as irssi's do.
    ///
    /// ⚠⚠ This is how an open list stays current after a Save — never a refetch. A fetch on
    /// the wire claims a 482 aimed at the MODE just sent (`server/services/modeList.ts`).
    public static func patch(_ entries: [ModeListEntry], with rows: [Message], letter: String) -> [ModeListEntry] {
        var out = entries
        for row in rows {
            for change in row.modes {
                guard change.kind == .list, change.letter == letter,
                      let param = change.param, !param.isEmpty
                else { continue }
                let at = out.firstIndex { $0.mask.lowercased() == param.lowercased() }
                if change.isGrant {
                    if at == nil { out.append(ModeListEntry(mask: param, setBy: row.nick, setAt: row.date)) }
                } else if let at {
                    out.remove(at: at)
                }
            }
        }
        return out
    }
}

/// The edits on a channel-settings screen that haven't been answered yet — only the rows the
/// user TOUCHED, never a copy of the channel taken when the screen opened.
///
/// Everything else reads the live state, and Save diffs the draft against the live state at
/// that moment. So another op's change while the screen is open shows up, and Save never
/// re-sends or reverts it (obby's stale-baseline bug).
///
/// ⚠⚠ An edit stays until the CHANNEL answers it, and is never cleared on the ack — the ack
/// only means the line went out. It goes when the live state matches it, or — for a row that
/// was saved — when that row's live state moves at all, since a server may echo a value
/// normalized (`+l 050` comes back as 50). A refusal moves nothing, so the edit stands beside
/// the error.
public struct ChannelModeDrafts: Equatable, Sendable {
    public private(set) var rows: [String: ChannelModeForm.DraftRow] = [:]
    /// The topic as typed; nil until the user types, and the field shows the live topic.
    public private(set) var topic: String?

    /// Per saved row: the live state it was saved from, and the edit that went out. Only that
    /// edit is the echo's to clear — the fields stay editable while the ack is out, and a newer
    /// edit (untick +m again before +m comes back) is the user's to keep.
    private var savedRows: [String: SavedRow] = [:]
    private var savedTopic: (live: String, sent: String)?

    public struct SavedRow: Equatable, Sendable {
        let live: ChannelModeForm.DraftRow
        let sent: ChannelModeForm.DraftRow
    }

    /// What a Save's mode changes are about to send, taken at the moment of Save — before any
    /// await, since the fields stay editable while it's out. Recorded by `noteSent` only once the
    /// changes actually go out.
    public struct Sending: Equatable, Sendable {
        fileprivate let rows: [String: SavedRow]
    }

    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rows == rhs.rows && lhs.topic == rhs.topic
    }

    public func shown(_ letter: String, live: ChannelModeForm.Live) -> ChannelModeForm.DraftRow {
        rows[letter] ?? live.row(letter)
    }

    public mutating func setOn(_ letter: String, _ on: Bool, live: ChannelModeForm.Live) {
        rows[letter] = ChannelModeForm.DraftRow(on: on, value: shown(letter, live: live).value)
    }

    public mutating func setValue(_ letter: String, _ value: String, live: ChannelModeForm.Live) {
        rows[letter] = ChannelModeForm.DraftRow(on: shown(letter, live: live).on, value: value)
    }

    public mutating func setTopic(_ text: String) { topic = text }

    /// The topic Save would send, or nil when it wouldn't change anything.
    public func topicChange(live: String) -> String? {
        guard let topic else { return nil }
        let out = ChannelModeForm.topicToSend(topic)
        return out == live ? nil : out
    }

    /// Capture what `changes` will send, as the rows stand now.
    public func sending(_ changes: [OutgoingModeChange], live: ChannelModeForm.Live) -> Sending {
        Sending(rows: Dictionary(uniqueKeysWithValues: Set(changes.map(\.letter)).map { letter in
            (letter, SavedRow(live: live.row(letter), sent: shown(letter, live: live)))
        }))
    }

    /// The changes are going out: the echo may now dissolve exactly those edits.
    ///
    /// ⚠ Only for changes that are actually SENT. A row recorded for a change that never left
    /// would be dissolved by any later move of that mode — another op's +m then -m quietly
    /// throwing away the user's unsent +m.
    public mutating func noteSent(_ sending: Sending) {
        savedRows.merge(sending.rows) { _, new in new }
    }

    /// The changes never went out after all: take back what `noteSent` recorded, unless a later
    /// Save has recorded over it.
    public mutating func noteNotSent(_ sending: Sending) {
        for (letter, row) in sending.rows where savedRows[letter] == row { savedRows[letter] = nil }
    }

    /// The topic is going out.
    public mutating func noteTopicSent(_ topic: String, liveTopic: String) {
        savedTopic = (live: liveTopic, sent: topic)
    }

    /// …or never did.
    public mutating func noteTopicNotSent(_ topic: String) {
        if savedTopic?.sent == topic { savedTopic = nil }
    }

    /// Let the live state answer what it can. Call on every state change.
    public mutating func reconcile(live: ChannelModeForm.Live, liveTopic: String) {
        for (letter, want) in rows {
            let was = live.row(letter)
            let matches = want.on == was.on
                && (!want.on || want.value.trimmingCharacters(in: .whitespacesAndNewlines) == was.value)
            let saved = savedRows[letter]
            let moved = saved.map { $0.live != was } ?? false
            if moved { savedRows[letter] = nil }
            if matches || (moved && saved?.sent == want) { rows[letter] = nil }
        }
        guard let topic else { return }
        let sending = ChannelModeForm.topicToSend(topic)
        let moved = savedTopic.map { $0.live != liveTopic } ?? false
        if sending == liveTopic || (moved && savedTopic?.sent == sending) { self.topic = nil }
        if moved { savedTopic = nil }
    }
}

/// What this account may do in a channel, as the channel settings screens ask it.
public struct ChannelAccess: Equatable, Sendable {
    /// The network's vocabulary, or nil while it's unknown.
    public let spec: ModeSpec?
    /// In the channel. A parted channel's modes are last-known, and a TOPIC or MODE from outside
    /// it only draws a 442.
    public let joined: Bool
    /// Op or higher, by the network's own PREFIX.
    public let canEditModes: Bool
    /// Halfop or higher under `+t`; anyone in the channel without it.
    public let canSetTopic: Bool
}

extension ChatState {
    /// Who may do what in `key`'s channel. The server has the last word — its refusal shows on
    /// the screen — so this only decides which controls are offered.
    public func channelAccess(_ key: BufferKey) -> ChannelAccess {
        let network = key.networkId.flatMap { networks[$0] }
        let spec = network?.modeSpec
        let joined = buffers[key.id]?.joined == true
        let nick = network?.nick.lowercased() ?? ""
        let mine = nick.isEmpty ? [] : (members[key.id]?.first { $0.nick.lowercased() == nick }?.modes ?? [])
        // Before the vocabulary arrives the conventional ladder gates — gating only, never
        // classifying, and the server refuses anything it got wrong.
        let prefix = spec?.prefix ?? ModeSpec.defaultPrefix
        let modes = channelModes[key.id]?.modes ?? ""
        return ChannelAccess(
            spec: spec,
            joined: joined,
            canEditModes: joined && ChannelRank.atLeast(mine, prefix: prefix, "o"),
            canSetTopic: joined && (!modes.contains("t") || ChannelRank.atLeast(mine, prefix: prefix, "h"))
        )
    }
}
