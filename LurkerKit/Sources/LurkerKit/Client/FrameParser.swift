// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Turns raw server JSON into typed `ServerFrame`s. The one place that knows the wire
/// format. Kinds the 1.0 foundation doesn't consume yet parse to `.ignored` rather
/// than failing. Pure and synchronous, so it runs on whatever thread the socket
/// callback arrives on.
enum FrameParser {

    /// Parse one WS text frame (discriminated by `kind`).
    static func parseWs(_ text: String) -> ServerFrame {
        guard let obj = object(from: text) else { return .ignored }
        switch obj["kind"] as? String {
        case "snapshot": return parseSnapshot(obj)
        // Carries no state of its own — its arrival *is* the message.
        case "backlog-complete": return .backlogComplete
        case "backlog": return parseBacklog(obj)
        case "history": return parseHistory(obj)
        case "irc": return parseLive(obj)
        case "read-state":
            let target = obj.string("target")
            return target.isEmpty ? .ignored : .readState(
                networkId: obj.intOrNull("networkId"),
                target: target,
                lastReadId: obj.int("lastReadId"),
                unread: obj.int("unread"),
                highlights: obj.int("highlights")
            )
        case "send-result":
            return .sendResult(
                clientId: obj.stringOrNull("clientId"),
                ok: obj.bool("ok"),
                error: obj.stringOrNull("error")
            )
        case "settings":
            // `changes` carries only what moved. An empty object is legal (the server sends
            // `changes || {}`) and simply patches nothing.
            //
            // `maxUploadBytes` is present only when the cap itself was touched — absent means
            // unchanged, which is why it stays optional all the way to the store.
            return .settingsChanged(
                parseSettingValues(obj["changes"]),
                maxUploadBytes: advertisedUploadCap(obj)
            )
        case "buffer-cleared":
            // The `/clear` marker's fan-out — this device's own ack AND every other device's
            // notice, which is the whole reason the marker is server-side (#121).
            let target = obj.string("target")
            return target.isEmpty ? .ignored : .bufferCleared(
                networkId: obj.intOrNull("networkId"),
                target: target,
                clearedBeforeId: clearedMarker(obj).beforeId,
                clearedAt: clearedMarker(obj).at
            )
        case "error":
            return .serverError(obj.string("text"))
        case "favorites-changed":
            // The FULL global order, replace wholesale — the same frame seeds the
            // connect burst, so this one handler covers seed and every correction.
            return .favoritesChanged(obj.objects("favorites").map { entry in
                FavoriteEntry(
                    networkId: entry.int("networkId"),
                    target: entry.string("target"),
                    bufferId: entry.int("bufferId")
                )
            })
        case "bookmark-updated":
            // The fan-out for a save/unsave made anywhere on the account, including this
            // device — the server echoes to every socket, so it's the one source of truth
            // and nothing renders a toggle optimistically. A zero id can't address a row.
            let messageId = obj.int("messageId")
            return messageId == 0
                ? .ignored
                : .bookmarkUpdated(messageId: messageId, saved: obj.bool("saved"))
        case "upload-progress":
            // Same trust posture as its siblings. A frame with no token can't be matched to
            // the upload it describes, and an unrecognized phase is a server saying something
            // this build has no rendering for — in both cases the readout is better off on the
            // indeterminate fallback it already shows than acting on a payload we can't read.
            //
            // `percent` is legitimately null (the phase has no number), which is NOT the same
            // as absent-and-therefore-zero: `int()` would read a missing key as 0% and freeze
            // the bar there for the whole send. `intOrNull` keeps the two apart.
            guard let token = obj.stringOrNull("token"),
                  let phase = UploadServerProgress.Phase(rawValue: obj.string("phase"))
            else { return .ignored }
            return .uploadProgress(
                token: token,
                progress: UploadServerProgress(
                    phase: phase,
                    percent: obj.intOrNull("percent"),
                    destination: obj.stringOrNull("destination")
                )
            )
        case "ignore-list-updated":
            // A frame with no usable `masks` array is dropped rather than read as "this scope
            // now has no rules". `objects()` answers `[]` for a missing, null or mistyped key,
            // and the store treats the payload as complete-for-that-scope — so without this
            // guard one malformed frame silently deletes every rule in the bucket, live, and
            // nothing re-seeds them short of a reconnect. A hide feature must not fail open.
            // Both siblings in this switch refuse a payload they can't trust the same way
            // (`buffer-closed` on an empty target).
            //
            // The check is on the raw value, not on emptiness: `masks: []` is a legitimate
            // "the last rule was removed" and has to keep working.
            guard obj["masks"] is [Any] else { return .ignored }
            // `networkId` is nullable and its null means the GLOBAL bucket — not the system
            // buffer, which is what a null networkId means on every other frame. `intOrNull`
            // keeps the two apart; `int()` would fold global onto network 0.
            return .ignoreListUpdated(
                networkId: obj.intOrNull("networkId"),
                rules: obj.objects("masks").map(parseIgnoreRule)
            )
        case "relay-bot-updated":
            // A mark is about one connection and one nick; neither can be inferred, and a frame
            // missing either would key a mark on nothing (network 0, or the empty nick — which
            // would then "match" every nick-less line). Refused rather than folded, the same
            // posture the siblings above take toward a payload they can't trust.
            let nick = obj.string("nick")
            guard let networkId = obj.intOrNull("networkId"), !nick.isEmpty else { return .ignored }
            return .relayBotUpdated(
                networkId: networkId,
                nick: nick,
                marked: obj.bool("marked"),
                pattern: obj.string("pattern")
            )
        case "nick-note-updated":
            // Refused on a missing half for the same reason as the relay mark above: a note
            // keyed on network 0, or on the empty nick, is a note about nobody that every
            // nick-less lookup would then find.
            let noteNick = obj.string("nick")
            guard let networkId = obj.intOrNull("networkId"), !noteNick.isEmpty else {
                return .ignored
            }
            // ⚠⚠ `note` must be PRESENT, not merely readable. An empty note is a delete, and
            // `string("note")` folds a missing or non-string field to `""` — so a malformed
            // frame would silently destroy something the user typed. An absent field is not a
            // statement that the note is empty (the same rule `InstanceFeatures` follows), and
            // the asymmetry decides it: refusing costs a missed update, accepting costs the
            // note. A real clear still passes, because `""` is present.
            guard obj.has("note"), let note = obj["note"] as? String else { return .ignored }
            return .nickNoteUpdated(
                networkId: networkId,
                nick: noteNick,
                note: note,
                updatedAt: ISOTime.parse(obj.stringOrNull("updatedAt"))
            )
        case "buffer-renamed":
            // Same trust posture as buffer-closed below: empty names can't
            // identify anything, so refuse rather than rename an arbitrary
            // buffer. networkId stays null-distinct for the same BufferKey
            // reason.
            let from = obj.string("from")
            let to = obj.string("to")
            return from.isEmpty || to.isEmpty
                ? .ignored
                : .bufferRenamed(
                    networkId: obj.intOrNull("networkId"),
                    from: from,
                    to: to,
                    bufferId: obj.intOrNull("bufferId"),
                    merged: obj.bool("merged"),
                    mergedFromBufferId: obj.intOrNull("mergedFromBufferId")
                )
        case "pins-changed":
            // `pinned` is the ordered target list; `pinnedIds` rides alongside it,
            // parallel-indexed, and is ignored here — this client addresses buffers by
            // (networkId, target) everywhere else, and reading both would be two spellings of
            // one list to keep in step.
            guard let networkId = obj.intOrNull("networkId") else { return .ignored }
            return .pinsChanged(networkId: networkId, pinned: (obj["pinned"] as? [String]) ?? [])
        case "buffer-closed":
            // `networkId` is genuinely nullable here (the system buffer), so read it as
            // optional rather than defaulting to 0 — `intOrNull` keeps a null distinct from
            // network 0 the way BufferKey needs. An empty target can't identify a buffer.
            let target = obj.string("target")
            return target.isEmpty
                ? .ignored
                : .bufferClosed(networkId: obj.intOrNull("networkId"), target: target)
        default:
            return .ignored
        }
    }

    /// Parse REST `GET /api/networks` into the roster (id → name).
    ///
    /// ⚠⚠ An unreadable body is `.ignored`, NOT an empty roster. `applyNetworks` is
    /// authoritative over membership — it removes networks the list doesn't name — so
    /// reporting "we couldn't read the answer" as "you have no networks" would wipe every
    /// network the user has, buffers included.
    static func parseNetworks(_ body: String) -> ServerFrame {
        guard let obj = object(from: body) else { return .ignored }
        // REST carries no live state; the WS snapshot fills state/nick in.
        // `position` is the user's own ordering, which this endpoint is already sorted by.
        // Read rather than inferred from the array index: the array is a snapshot of one
        // response, and the store holds networks in a dictionary that has no order at all.
        // Absent (an older server) reads as `Int.max`, so those networks sort last instead of
        // all colliding at 0 and re-sorting by id.
        // `blocked` is the third REST-only field, read as `parseNetworkConfigs` reads it: absent
        // means "not blocked", the honest answer on a server with no allowlist.
        let networks = obj.objects("networks").map {
            Network(
                id: $0.int("id"), name: $0.stringOrNull("name"), position: $0.int("position", .max),
                blocked: $0.bool("blocked")
            )
        }
        return .networks(networks)
    }

    /// Parse REST `GET /api/networks` into the editable configuration rows (#11).
    ///
    /// Same response as `parseNetworks` above, read for a different purpose: that one takes
    /// the two fields the roster needs, this one takes everything the networks screen and its
    /// form do. Two readers rather than one union type, because the roster is reduced into
    /// long-lived state on every connect and this is fetched, shown, and dropped.
    /// ⚠ Nil for an unreadable body, never an empty array — the same distinction
    /// `parseNetworks` draws, for the caller's benefit rather than the store's. "No networks"
    /// is a real answer and the screen's empty state invites you to add your first one;
    /// "we couldn't read the reply" is an error. An empty array for both would show a fresh
    /// account's welcome to someone whose request failed.
    static func parseNetworkConfigs(_ body: String) -> [NetworkConfig]? {
        guard let obj = object(from: body) else { return nil }
        return obj.objects("networks").map(parseNetworkConfig)
    }

    static func parseNetworkConfig(_ obj: [String: Any]) -> NetworkConfig {
        NetworkConfig(
            id: obj.int("id"),
            name: obj.string("name"),
            host: obj.string("host"),
            // A row predating a port column, or one a hand-written client POSTed without one,
            // reads 0 — which is not a port. The server's own default is the honest stand-in.
            port: obj.int("port") == 0 ? 6697 : obj.int("port"),
            tls: obj.bool("tls"),
            // ⚠ Defaults TRUE, unlike every other flag here. It means `rejectUnauthorized`,
            // so an absent value read as false would report a network as not verifying its
            // certificate when the server's column says it does — and the form would then
            // save that misreading back.
            trustedCertificates: obj.bool("trusted_certificates", true),
            nick: obj.string("nick"),
            username: obj.stringOrNull("username"),
            realname: obj.stringOrNull("realname"),
            autoconnect: obj.bool("autoconnect"),
            saslAccount: obj.stringOrNull("sasl_account"),
            connectCommands: obj.stringOrNull("connect_commands"),
            hasPassword: obj.bool("has_password"),
            hasSaslPassword: obj.bool("has_sasl_password"),
            // Absent on a server older than the allowlist (#298), and absent must read as
            // "not blocked": an older server has no allowlist to be excluded from, and
            // defaulting the other way would grey out every network on it.
            blocked: obj.bool("blocked")
        )
    }

    /// One network row from a create/update reply — `{network: {...}}`.
    static func parseNetworkReply(_ body: String) -> NetworkConfig? {
        guard let obj = object(from: body), let row = obj["network"] as? [String: Any] else { return nil }
        return parseNetworkConfig(row)
    }

    /// Parse REST `GET /api/network-presets` — the networks this instance recommends, plus
    /// whether users may connect to anything else (#298).
    ///
    /// ⚠ `allowUserDefined` defaults TRUE on a missing key. A server predating the lockdown
    /// has no such policy, and reading its silence as "locked down" would hide the
    /// custom-server path on every older instance — leaving an app that can't add a network,
    /// which is the whole failure #11 exists to fix.
    static func parseNetworkPresets(_ body: String) -> NetworkPresets? {
        guard let obj = object(from: body) else { return nil }
        return NetworkPresets(
            instance: obj.objects("presets").map { preset in
                NetworkPreset(
                    name: preset.string("name"),
                    host: preset.string("host"),
                    port: preset.int("port", 6697),
                    tls: preset.bool("tls", true),
                    saslLikelyRequired: preset.bool("saslLikelyRequired"),
                    recommendedChannels: (preset["channels"] as? [String]) ?? [],
                    isInstance: true,
                    instanceID: preset.intOrNull("id")
                )
            },
            allowUserDefined: obj.bool("allowUserDefined", true)
        )
    }

    /// Parse REST `GET /api/highlights` into a page. Each item is a `MessageEvent` spread
    /// flat (so `parseEvent` reads it, same as a backlog line) plus the buffer address
    /// (`networkId`/`target`) and a resolved `networkName`. `nextBefore` is the cursor for
    /// the next older page, null at the end — carried through as `Int?` so `hasMore` can
    /// distinguish "no more" from "more, cursor 0".
    static func parseHighlights(_ body: String) -> HighlightsPage {
        guard let obj = object(from: body) else { return HighlightsPage(items: [], nextBefore: nil) }
        return HighlightsPage(
            items: obj.objects("items").map(parseFeedItem),
            nextBefore: obj.intOrNull("nextBefore")
        )
    }

    /// Parse REST `GET /api/uploads` into a page of history rows (#138).
    ///
    /// ⚠ No `nextBefore` in this envelope, unlike the three message feeds — the caller pages on
    /// the last row's id and reads a short page as the end. `UploadsRequest.hasMore` holds that
    /// rule, along with the starred view's exception to it.
    ///
    /// ⚠⚠ `removed` is not a flag on an otherwise-normal row. The server sends a moderated
    /// takedown as a tombstone — no `can_delete`, no thumbnail — because the bytes are gone, so
    /// everything the row would otherwise offer (view, share, copy, insert) is dead for one. Read
    /// back as false/nil rather than defaulted into something that looks live.
    static func parseUploads(_ body: String) -> UploadsPage {
        guard let obj = object(from: body) else { return UploadsPage(items: []) }
        return UploadsPage(items: obj.objects("items").map(parseUpload))
    }

    private static func parseUpload(_ row: [String: Any]) -> UploadItem {
        UploadItem(
            id: row.int("id"),
            url: row.string("url"),
            filename: row.stringOrNull("filename"),
            mime: row.stringOrNull("mime"),
            byteSize: row.intOrNull("byte_size"),
            createdAt: ISOTime.parse(row.stringOrNull("created_at")),
            favorite: row.bool("favorite"),
            canDelete: row.bool("can_delete"),
            thumbnailPath: row.stringOrNull("thumbnail_url"),
            removed: row.bool("removed")
        )
    }

    /// One cross-buffer feed row: a `MessageEvent` spread flat (so `parseEvent` reads it, same
    /// as a backlog line) plus the buffer address (`networkId`/`target`) and a server-resolved
    /// `networkName`. Shared by highlights, bookmarks and search.
    private static func parseFeedItem(_ item: [String: Any]) -> HighlightItem {
        HighlightItem(
            message: parseEvent(item),
            networkId: item.intOrNull("networkId"),
            target: item.string("target"),
            networkName: item.stringOrNull("networkName")
        )
    }

    // MARK: - Private

    private static func object(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func parseSnapshot(_ obj: [String: Any]) -> ServerFrame {
        let networks = obj.objects("networks").map { network in
            NetworkSnapshot(
                id: network.int("networkId"),
                state: ConnectionState.from(network.stringOrNull("state")),
                nick: network.string("nick"),
                channels: network.objects("channels").map(parseChannel),
                peerPresence: parsePeerPresence(network["peerPresence"] as? [String: Any]),
                ignoredMasks: network.objects("ignoredMasks").map(parseIgnoreRule),
                relayBots: network.objects("relayBots").compactMap(parseRelayBot),
                nickNotes: network.objects("nickNotes").compactMap(parseNickNote),
                away: parseAwayState(network["away"]),
                pinned: (network["pinned"] as? [String]) ?? []
            )
        }
        return .snapshot(
            networks,
            globalIgnores: obj.objects("globalIgnores").map(parseIgnoreRule),
            maxUploadBytes: advertisedUploadCap(obj)
        )
    }

    /// The advertised upload cap off a frame that may carry one, or nil for "didn't say".
    ///
    /// ⚠ A non-positive number is read as "didn't say" too. The server never sends one, and a
    /// cap no file can satisfy is not a statement about anything — taken at face value it
    /// would send every video down the preset ladder to `.cannotCompressEnough`, which reads
    /// to the user as the app refusing to upload rather than as a server that answered
    /// nonsense. Same discipline as an absent field: only a real answer is an answer.
    private static func advertisedUploadCap(_ obj: [String: Any]) -> Int? {
        guard let bytes = obj.intOrNull("maxUploadBytes"), bytes > 0 else { return nil }
        return bytes
    }

    /// One stored ignore rule. Shared by the snapshot's two seeds (per-network `ignoredMasks`
    /// and the frame-level `globalIgnores`) and by `ignore-list-updated`, which is the same
    /// row shape in all three.
    ///
    /// Absent optional fields read as "unconstrained", which is what the matcher wants: no
    /// mask is anyone, no channels is everywhere, no pattern is any body. `levels` arrives
    /// already canonicalized by the server, so the irssi alias spellings never reach here.
    private static func parseIgnoreRule(_ obj: [String: Any]) -> IgnoreRule {
        IgnoreRule(
            id: obj.int("id"),
            mask: obj.stringOrNull("mask"),
            channels: obj["channels"] as? [String],
            pattern: obj.stringOrNull("pattern"),
            patternKind: IgnorePatternKind.from(obj.stringOrNull("patternKind")),
            levels: (obj["levels"] as? [String]) ?? [],
            isExcept: obj.bool("isExcept"),
            // Parsed here rather than compared as a string at match time: expiry is checked
            // once per rule per rendered row, and `Date.parse` on every one of those would be
            // the most expensive thing in the filter.
            expiresAt: ISOTime.parse(obj.stringOrNull("expiresAt"))
        )
    }

    /// One relay-bot mark (#277) — the same `{nick, pattern}` row in the snapshot's per-network
    /// `relayBots` and in a `relay-bot-updated` frame.
    ///
    /// A row with no nick addresses nobody, so it's dropped rather than becoming a mark keyed on
    /// the empty string — which would match every nick-less line the client ever renders. An
    /// absent `pattern` is the built-in formats, which is what the server stores for a bare mark.
    private static func parseRelayBot(_ obj: [String: Any]) -> RelayBot? {
        let nick = obj.string("nick")
        return nick.isEmpty ? nil : RelayBot(nick: nick, pattern: obj.string("pattern"))
    }

    /// One stored nick note (#12) — the same `{nick, note, updatedAt}` row in the snapshot's
    /// per-network `nickNotes` and in a `nick-note-updated` frame.
    ///
    /// A row with no nick is about nobody; an empty note is the server's spelling of "no note"
    /// (`set_nick_note` deletes the row rather than storing a blank), so neither becomes an
    /// entry. Dropping the blank here is what keeps `hasNote` from answering yes to a note that
    /// was cleared.
    private static func parseNickNote(_ obj: [String: Any]) -> NickNote? {
        let nick = obj.string("nick")
        let note = obj.string("note")
        guard !nick.isEmpty, !note.isEmpty else { return nil }
        return NickNote(nick: nick, note: note, updatedAt: ISOTime.parse(obj.stringOrNull("updatedAt")))
    }

    /// The `whois` payload of a `whois_result` frame (#12).
    ///
    /// ⚠⚠ The field names are **irc-framework's**, not Lurker's: the server does not reshape
    /// this object, it forwards the one irc-framework assembled from the RPL_WHOIS* numerics
    /// (`ircConnection.ts:2912`). `real_name`, `actual_ip`, `server_info` and
    /// `registered_nick` are its spellings and are load-bearing here.
    ///
    /// ⚠⚠ `idle` and `logon` are **numeric-valued strings**, not numbers. irc-framework assigns
    /// them straight off `command.params` (`user.js:238`), and IRC parameters are text — so a
    /// bare `as? Int` reads nil on every real reply. `numericField` takes either.
    private static func parseWhois(_ obj: [String: Any]) -> WhoisResult {
        WhoisResult(
            nick: obj.string("nick"),
            ident: obj.stringOrNull("ident"),
            hostname: obj.stringOrNull("hostname"),
            realName: obj.stringOrNull("real_name"),
            actualHostname: obj.stringOrNull("actual_hostname"),
            actualIP: obj.stringOrNull("actual_ip"),
            server: obj.stringOrNull("server"),
            serverInfo: obj.stringOrNull("server_info"),
            account: obj.stringOrNull("account"),
            channelsLine: obj.stringOrNull("channels"),
            modes: obj.stringOrNull("modes"),
            isOperator: obj.stringOrNull("operator"),
            helpop: obj.stringOrNull("helpop"),
            bot: obj.stringOrNull("bot"),
            registeredNick: obj.stringOrNull("registered_nick"),
            isSecure: obj.bool("secure"),
            certfp: obj.stringOrNull("certfp"),
            away: obj.stringOrNull("away"),
            idleSeconds: numericField(obj["idle"]),
            // Unix seconds. Distinguished from "absent" rather than defaulted, because a
            // signon at the epoch would render as 1970 — plausible-looking and wrong, where a
            // missing row simply doesn't draw.
            signedOn: numericField(obj["logon"]).map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            error: obj.stringOrNull("error")
        )
    }

    /// A wire number that may have arrived as a string. See `parseWhois` for why that happens.
    private static func numericField(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// The snapshot's `peerPresence` blob — `lowercased nick → {nick, state, stateAt,
    /// awayMessage}` — flattened to the one field the client acts on. Entries whose `state`
    /// isn't a known value (or is null) are dropped, which reads as `unknown`, exactly as a
    /// live null-state event would.
    private static func parsePeerPresence(_ blob: [String: Any]?) -> [String: PresenceState] {
        guard let blob else { return [:] }
        var out: [String: PresenceState] = [:]
        for (nick, value) in blob {
            guard let entry = value as? [String: Any],
                  let raw = entry["state"] as? String,
                  let state = PresenceState(rawValue: raw)
            else { continue }
            out[nick.lowercased()] = state
        }
        return out
    }

    /// The `away` blob — `{active, since, message, autoSet, backAt}` — shared by the network
    /// snapshot and the live `away-state` event, which carry the identical shape.
    ///
    /// A null (or missing, or mistyped) blob is nil, not a default-constructed state: the
    /// server sends `away: null` for an account with nothing on record, and inventing an
    /// `active: false` there would be a claim that the user *returned* rather than that we
    /// were never told anything. A blob carrying no readable `since` is nil for the same
    /// reason — see below.
    private static func parseAwayState(_ raw: Any?) -> AwayState? {
        guard let obj = raw as? [String: Any] else { return nil }
        // `since` is the field the whole feature hangs on — both markers are placed from it, and
        // the server itself treats it as the existence test (`away = a.since ? {…} : null`, in
        // both the snapshot and `publishAwayState`). So a blob we can't read one out of is a
        // blob no marker can be placed from, and reading it as an away with no beginning would
        // put a value in the store that nothing can use and nothing can retract.
        //
        // `active` and `autoSet` keep the file's ordinary `bool()` default. Nothing in the
        // placement logic reads either — `MessageRows` works from `since` and `backAt` alone —
        // so a defaulted `false` can't manufacture a marker: only a parsed `backAt` does that.
        guard let since = ISOTime.parse(obj.stringOrNull("since")) else { return nil }
        return AwayState(
            active: obj.bool("active"),
            message: obj.stringOrNull("message"),
            since: since,
            autoSet: obj.bool("autoSet"),
            backAt: ISOTime.parse(obj.stringOrNull("backAt"))
        )
    }

    private static func parseChannel(_ channel: [String: Any]) -> ChannelSnapshot {
        ChannelSnapshot(
            name: channel.string("name"),
            topic: channel.stringOrNull("topic"),
            members: channel.objects("members").map(parseMember)
        )
    }

    /// The server's `memberSnapshot` shape — identical on a snapshot channel, a `names`
    /// broadcast, and a `member-update` patch, so all three parse through here.
    private static func parseMember(_ member: [String: Any]) -> Member {
        Member(
            nick: member.string("nick"),
            modes: (member["modes"] as? [String]) ?? [],
            away: member.bool("away"),
            user: member.stringOrNull("user"),
            host: member.stringOrNull("host")
        )
    }

    /// Decode a REST body to a JSON object, for the callers that need a field this file has no
    /// dedicated parse for (`PATCH /api/settings` → `{values}`). Still routed through here so
    /// `JSONSerialization` stays behind the one type that knows the wire format.
    static func jsonObject(from text: String) -> [String: Any]? {
        object(from: text)
    }

    /// The `error` string from a REST failure body (`{error, key}`), when there is one. Lives
    /// here rather than at the call site because this is the one place that knows the wire
    /// format — and the server's own wording ("must be one of …", "out of range") is more use
    /// to the user than anything the caller could invent.
    static func errorMessage(from text: String) -> String? {
        object(from: text)?.stringOrNull("error")
    }

    /// A `{key: value}` blob of settings — the `values` half of bootstrap, and the `changes`
    /// of a live update. Anything whose value doesn't decode to a `SettingValue` is skipped
    /// rather than guessed at: a key we can't represent is one we also can't write back.
    static func parseSettingValues(_ raw: Any?) -> [String: SettingValue] {
        guard let object = raw as? [String: Any] else { return [:] }
        return object.reduce(into: [:]) { out, pair in
            if let value = SettingValue.from(pair.value) { out[pair.key] = value }
        }
    }

    /// A registry entry's `dependsOn` clauses (#666), if it carries any.
    ///
    /// A clause whose `in` list holds nothing this app can represent is dropped rather than
    /// kept empty: an empty value list can never match, so keeping it would permanently grey
    /// out a control on the strength of a value we simply failed to parse.
    private static func parseDependencies(_ raw: Any?) -> [SettingDependency] {
        guard let entries = raw as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            let key = entry.string("key")
            let values = ((entry["in"] as? [Any]) ?? []).compactMap(SettingValue.from)
            guard !key.isEmpty, !values.isEmpty else { return nil }
            return SettingDependency(key: key, values: values)
        }
    }

    /// `GET /api/settings/bootstrap` → `{registry, values}`.
    ///
    /// The registry is an ARRAY of options on the wire (it's `REGISTRY` verbatim), keyed here
    /// so lookups are by key rather than a linear scan per read.
    static func parseSettingsBootstrap(_ text: String) -> ServerFrame {
        guard let obj = object(from: text) else { return .ignored }
        var registry: [String: SettingOption] = [:]
        for entry in (obj["registry"] as? [[String: Any]]) ?? [] {
            let key = entry.string("key")
            guard !key.isEmpty, let type = SettingType(rawValue: entry.string("type")) else { continue }
            // A registry entry with no usable default is unusable: `effective` would return nil
            // for an unset key and every caller would silently fall through to its own
            // fallback, which is the drift this whole layer exists to prevent.
            guard let defaultValue = entry["default"].flatMap(SettingValue.from) else { continue }
            registry[key] = SettingOption(
                key: key,
                label: entry.string("label"),
                description: entry.string("description"),
                type: type,
                default: defaultValue,
                choices: (entry["choices"] as? [String]) ?? [],
                choiceLabels: (entry["choiceLabels"] as? [String: String]) ?? [:],
                min: entry.intOrNull("min"),
                max: entry.intOrNull("max"),
                dependsOn: parseDependencies(entry["dependsOn"])
            )
        }
        return .settingsBootstrap(registry: registry, values: parseSettingValues(obj["values"]))
    }

    private static func parseBacklog(_ obj: [String: Any]) -> ServerFrame {
        let target = obj.string("target")
        if target.isEmpty { return .ignored }
        let networkId = obj.intOrNull("networkId")
        let events = obj.objects("events")
        // A shell is `events: []` + `hasMoreOlder: true` — the "unhydrated, fetch on
        // open" marker. Any real events, or a frame that isn't claiming more older,
        // means we have this buffer's history. Read `hasMoreOlder` once with a `true`
        // fallback (matching Buffer's default): if a server ever omits it on an empty
        // frame, treating the buffer as a shell (→ fetch) is safe; the `false` fallback
        // would mislabel it hydrated and it would render empty forever.
        let hasMoreOlder = obj.bool("hasMoreOlder", true)
        let hydrated = !events.isEmpty || !hasMoreOlder
        // For a *network* buffer, only a resume slice carries a `reset` field. reset:false
        // means "these are just the events past ?since" → append; reset:true (oversized
        // gap) and a plain full/latest backlog (no field) → replace.
        //
        // The system buffer is the exception, and reading it the same way corrupts it: the
        // server's `buildSystemBacklog` hardcodes `reset: false` on EVERY connect, because
        // it always ships a full latest slice and expects the client to reconcile it — it
        // is never a resume delta. Appending it instead would (a) splice the whole history
        // *after* any live system line that beat the backlog in, and (b) leave a permanent
        // hole when a reconnect gap exceeds the server's slice cap. Replacing is what the
        // server means, and the replace path already preserves live events past the tail.
        let append = networkId != nil && obj.has("reset") && !obj.bool("reset")
        let buffer = Buffer(
            networkId: networkId,
            target: target,
            kind: BufferKind.of(networkId: networkId, target: target),
            unread: obj.int("unread"),
            highlights: obj.int("highlights"),
            lastReadId: obj.int("lastReadId"),
            joined: obj.bool("joined"),
            hydrated: hydrated,
            // Read from the FIELD'S PRESENCE, not its value: `int()` reads a missing
            // `lastReadId` as 0, which is also a legitimate "read nothing". Only a frame that
            // actually carried the pointer may claim to have stated it — see
            // `Buffer.readStateKnown`.
            readStateKnown: obj.has("lastReadId"),
            hasMoreOlder: hasMoreOlder,
            clearedBeforeId: clearedMarker(obj).beforeId,
            clearedAt: clearedMarker(obj).at,
            // The connect burst doubles as the id directory (§5.2): every
            // backlog frame carries the buffer's stable id.
            bufferId: obj.intOrNull("bufferId")
        )
        return .backlog(
            buffer: buffer, messages: events.map(parseEvent), hydrated: hydrated, append: append,
            speakers: parseSpeakers(obj)
        )
    }

    /// The `/clear` marker off a frame that carries one (#121) — both halves, or neither.
    ///
    /// ⚠ Negatives and zero are "never cleared". The server treats `<= 0` as no marker
    /// (`bufferReads.ts`: "boundary id <= 0 clears the marker"), and a negative reaching the
    /// row filter would compare against every id and hide nothing anyway.
    ///
    /// ⚠⚠ A boundary with no readable instant is discarded WHOLE. Those two states are one
    /// fact, and half of it hides every row while drawing no divider to undo with — the server
    /// allows a null `cleared_at` and its rename/case-fold merges carry the columns
    /// independently, so this is reachable from the wire rather than only from a bug here.
    private static func clearedMarker(_ obj: [String: Any]) -> (beforeId: Int, at: Date?) {
        let beforeId = obj.int("clearedBeforeId")
        guard beforeId > 0, let at = ISOTime.parse(obj.stringOrNull("clearedAt")) else {
            return (0, nil)
        }
        return (beforeId, at)
    }

    private static func parseLive(_ obj: [String: Any]) -> ServerFrame {
        // `peer-presence` is network-scoped state routed by `nick`, not a buffer line — its
        // `:server:<id>` target is only a carrier. Handle it before the target guard below so
        // the presence handler never depends on an unrelated field: no id, nothing to render,
        // and `state` may be null → nil → `unknown`.
        if obj.string("type") == "peer-presence" {
            guard let networkId = obj.intOrNull("networkId") else { return .ignored }
            let nick = obj.string("nick")
            if nick.isEmpty { return .ignored }
            return .peerPresence(
                networkId: networkId,
                nick: nick,
                state: PresenceState(rawValue: obj.string("state"))
            )
        }
        // `away-state` is network-scoped state like `peer-presence`, and its `:server:<id>`
        // target is the same kind of carrier — so it's handled above the target guard too,
        // and for the extra reason that its payload is legitimately *null*: an account with
        // no away on record sends `away: null`, which is a value to store rather than a frame
        // to drop.
        if obj.string("type") == "away-state" {
            guard let networkId = obj.intOrNull("networkId") else { return .ignored }
            return .awayState(networkId: networkId, away: parseAwayState(obj["away"]))
        }
        // `own-nick` is network-scoped state too, and carries no target at all — the visible
        // line is the ordinary `nick` event fanned out per channel, which arrives separately.
        // Below the target guard it would be dropped, leaving `Network.nick` pinned to whatever
        // the connect snapshot said for the rest of the session.
        if obj.string("type") == "own-nick" {
            guard let networkId = obj.intOrNull("networkId") else { return .ignored }
            let nick = obj.string("nick")
            if nick.isEmpty { return .ignored }
            return .ownNick(networkId: networkId, nick: nick)
        }
        // `state` is the connection indicator's only live source, and it was being DROPPED.
        //
        // The server publishes one on every transition (`ircConnection.setState`,
        // unconditionally — the comment there says it exists to keep a late-attaching client
        // in sync). Without a case here it folded to `.other`, and since it carries no `text`
        // it rendered nowhere either: the per-network `state` the app showed came only from
        // the connect `snapshot` and was then frozen for the session. So a network that
        // dropped still read as connected, one that came back still read as disconnected,
        // and under #11 the Connect button would have appeared to do nothing.
        //
        // `nick` rides along on the connect transition only, so it's optional here — an
        // absent one must not blank the nick the snapshot gave us.
        if obj.string("type") == "state" {
            guard let networkId = obj.intOrNull("networkId") else { return .ignored }
            let nick = obj.string("nick")
            return .networkState(
                networkId: networkId,
                state: ConnectionState.from(obj.stringOrNull("state")),
                nick: nick.isEmpty ? nil : nick
            )
        }
        // `whois_result` is about a *person on a network*, not about a conversation, so it
        // carries no target at all — like `own-nick`, and unlike the `:server:<id>` carriers
        // above. Below the guard it folds to `.other` and is discarded, which is why `/whois`
        // has never done anything on this client but write numerics to the server buffer.
        //
        // With no `nick` there is nothing to key it on. The server can't send one — even a
        // miss carries it, synthesized at RPL_ENDOFWHOIS — and a reply we can't address is one
        // no screen can be waiting for.
        if obj.string("type") == "whois_result" {
            guard let networkId = obj.intOrNull("networkId"),
                  let payload = obj["whois"] as? [String: Any],
                  !payload.string("nick").isEmpty
            else { return .ignored }
            return .whoisResult(networkId: networkId, whois: parseWhois(payload))
        }
        let target = obj.string("target")
        if target.isEmpty { return .ignored }
        // `channel-topic` rides the `irc` kind like everything else, but it isn't an event
        // in the sense the rest of this function means: no id, nothing to render, and its
        // payload is in `topic` rather than `text`. Left to `parseEvent` it would become an
        // `.other` Message appended to the buffer, carrying the topic in a field nothing
        // reads.
        if obj.string("type") == "channel-topic" {
            return .channelTopic(
                networkId: obj.intOrNull("networkId"),
                target: target,
                topic: obj.stringOrNull("topic")
            )
        }
        // `names` and `member-update` are state-only for the same reason as
        // `channel-topic`: no id, nothing to render, payload in fields `parseEvent`
        // doesn't read. Left to fall through they'd become `.other` Messages that
        // carry the member data in no field at all.
        if obj.string("type") == "names" {
            return .channelMembers(
                networkId: obj.intOrNull("networkId"),
                target: target,
                members: obj.objects("members").map(parseMember)
            )
        }
        // `typing` is ephemeral state like the three around it — no id, nothing to render —
        // and its payload lives in `state`, which `parseEvent` doesn't read. Note this sits
        // BELOW the target guard: unlike `peer-presence`, a typing tag is meaningless without
        // knowing which conversation it's about.
        if obj.string("type") == "typing" {
            let nick = obj.string("nick")
            // Nobody to attribute it to. (The server always sends one; a malformed frame
            // shouldn't become an entry keyed on the empty string.)
            if nick.isEmpty { return .ignored }
            return .typing(
                networkId: obj.intOrNull("networkId"),
                target: target,
                nick: nick,
                activity: TypingActivity.from(obj.stringOrNull("state")),
                userhost: obj.stringOrNull("userhost")
            )
        }
        if obj.string("type") == "member-update" {
            // A patch with no nick has nobody to apply to.
            guard let member = obj["member"] as? [String: Any], !member.string("nick").isEmpty
            else { return .ignored }
            return .memberUpdate(
                networkId: obj.intOrNull("networkId"),
                target: target,
                member: parseMember(member)
            )
        }
        return .live(networkId: obj.intOrNull("networkId"), target: target, message: parseEvent(obj))
    }

    private static func parseHistory(_ obj: [String: Any]) -> ServerFrame {
        let target = obj.string("target")
        if target.isEmpty { return .ignored }
        let mode = HistoryMode(rawValue: obj.string("mode")) ?? .before
        // `hasMore` is a legacy alias for `hasMoreOlder`; prefer the explicit field.
        return .history(
            networkId: obj.intOrNull("networkId"),
            target: target,
            events: obj.objects("events").map(parseEvent),
            mode: mode,
            hasMoreOlder: obj.bool("hasMoreOlder", obj.bool("hasMore")),
            hasMoreNewer: obj.bool("hasMoreNewer"),
            speakers: parseSpeakers(obj)
        )
    }

    /// The server's recent-speakers list, or nil if the frame didn't carry one.
    ///
    /// Read from the field's PRESENCE rather than from an empty parse, because the wire draws
    /// the distinction and this type mirrors the wire (see `ServerFrame.backlog`): a frame that
    /// shipped `speakers: []` is saying nobody has spoken, and one that shipped nothing is
    /// saying nothing at all.
    ///
    /// `lastTime` is epoch milliseconds. Entries missing either half are dropped rather than
    /// defaulted: a speaker at the epoch reads as infinitely stale, which is the same as being
    /// absent but harder to notice.
    private static func parseSpeakers(_ obj: [String: Any]) -> [Speaker]? {
        guard obj.has("speakers") else { return nil }
        return obj.objects("speakers").compactMap { entry in
            let nick = entry.string("nick")
            let lastTime = entry.int("lastTime")
            guard !nick.isEmpty, lastTime > 0 else { return nil }
            return Speaker(
                nick: nick, lastSpoke: Date(timeIntervalSince1970: TimeInterval(lastTime) / 1000)
            )
        }
    }

    /// MessageEvent → domain `Message`. Events are spread flat on the frame, so the
    /// same reader handles both a backlog array element and a live `irc` frame.
    ///
    /// `level` and `originNetworkId` are only ever set on system-buffer lines, and are
    /// nil everywhere else — severity there is a sibling field, not a `type`.
    private static func parseEvent(_ event: [String: Any]) -> Message {
        let time = event.stringOrNull("time")
        let type = EventType.from(event.stringOrNull("type"))
        return Message(
            id: event.int("id"),
            type: type,
            nick: event.stringOrNull("nick"),
            text: event.stringOrNull("text"),
            isSelf: event.bool("self"),
            time: time,
            date: ISOTime.parse(time),
            matched: event.bool("matched"),
            level: type == .system ? SystemLevel.from(event.stringOrNull("level")) : nil,
            // Gated like `level`, matching the server: `systemLineToEvent` is the only
            // producer of this field and only ever builds `type: "system"` events, so
            // reading it anywhere else would be inventing a meaning the wire doesn't have.
            originNetworkId: type == .system ? event.intOrNull("originNetworkId") : nil,
            // The server's `extractExtras` spreads these onto the event for exactly one
            // type each — `newNick` on nick, `kicked` on kick, `invited` on invite, `modes`
            // on mode, `newIdent`/`newHost` on chghost, `account` on join. Reading them
            // unconditionally is harmless (they're absent otherwise), and the renderer only
            // reaches for the one its type implies.
            newNick: event.stringOrNull("newNick"),
            kicked: event.stringOrNull("kicked"),
            invited: event.stringOrNull("invited"),
            modes: event.objects("modes").map {
                ModeChange(
                    mode: $0.string("mode"),
                    param: $0.stringOrNull("param"),
                    // Absent on rows older than the server-side stamp, and on any server
                    // that doesn't send it. Unknown values decode to nil for the same
                    // reason: an unclassified change is shown, never guessed at.
                    kind: $0.stringOrNull("kind").flatMap(ModeChangeKind.init(rawValue:))
                )
            },
            newIdent: event.stringOrNull("newIdent"),
            newHost: event.stringOrNull("newHost"),
            // Not an extra — a real column on the messages table, so it survives backlog for
            // every event type that had one (`server/db/messages.ts:157`).
            userhost: event.stringOrNull("userhost"),
            account: event.stringOrNull("account"),
            // Absent means unsaved — the server omits the field rather than sending false,
            // since nearly every row in every backlog is unsaved. See Message.bookmarked
            // for why the store's id set, not this, is what the UI reads.
            bookmarked: event.bool("bookmarked")
        )
    }
}
