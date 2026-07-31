// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import Foundation

/// Owns the client + store for the app's lifetime. The client does I/O and emits frames;
/// the store folds them into `state`; the UI observes `statePublisher`. This is the seam
/// the foundation issues hook into.
///
/// Owns two lifecycles:
///  - **session (#3):** restore a Keychain-persisted token on launch; a mid-session 401
///    bounces cleanly to sign-in.
///  - **connection (#4):** reconnect with backoff when the socket drops, resuming from the
///    highest event id seen (`?since=`); and on return-to-foreground, reconnect a socket
///    that died while backgrounded. The app feeds foreground/background via
///    `enterForeground()`/`enterBackground()` (keeping this package UIKit-free).
@MainActor
public final class ChatViewModel {

    /// Where the account stands with the server.
    public enum SessionState: Sendable {
        case loggedOut
        case loggingIn
        case loggedIn
    }

    private let store = LurkerStore()
    private let sessions: SessionStore
    private lazy var client = LurkerClient(onFrame: { [weak self] frame in self?.handle(frame) })

    private let sessionSubject = CurrentValueSubject<SessionState, Never>(.loggedOut)
    private let statusSubject = CurrentValueSubject<String?, Never>(nil)

    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var isForeground = true
    private var backgroundedAt: Date?
    /// Buffer keys with an older-history page in flight, so scroll-up can't spam requests.
    private var loadingOlder: Set<String> = []
    /// Buffer keys with a newer-history page in flight (#45), so scroll-down can't spam requests.
    private var loadingNewer: Set<String> = []
    /// Highest message id we've already marked read per buffer, to dedupe mark-read spam.
    private var lastMarked: [String: Int] = [:]

    /// Last-known setting values, so behavior is right from the first frame rather than from
    /// whenever the bootstrap fetch lands — see `SettingsCache`.
    private let settingsCache: SettingsCache

    public init(sessions: SessionStore = SessionStore(), settingsCache: SettingsCache = SettingsCache()) {
        self.sessions = sessions
        self.settingsCache = settingsCache
        // Seed before anything can read a setting. Patched in as *values* only — no registry —
        // so `settings.loaded` stays honestly false until a real bootstrap arrives, while every
        // behavior gate already reads the user's actual choice.
        let cached = settingsCache.load()
        if !cached.isEmpty { store.apply(.settingsChanged(cached)) }
        restoreSession()
    }

    // MARK: - What the UI observes

    public var state: ChatState { store.state }
    public var statePublisher: AnyPublisher<ChatState, Never> { store.statePublisher }

    public var session: SessionState { sessionSubject.value }
    public var sessionPublisher: AnyPublisher<SessionState, Never> { sessionSubject.eraseToAnyPublisher() }

    /// Transient status/error text for the login screen (why a sign-in failed, or why a
    /// session ended).
    public var statusPublisher: AnyPublisher<String?, Never> { statusSubject.eraseToAnyPublisher() }

    // MARK: - Actions

    /// Password → session token → roster + socket, and persist the session so the next
    /// launch reconnects without re-login. Returns whether sign-in succeeded; on failure
    /// `statusPublisher` carries the reason.
    @discardableResult
    public func login(backend: Backend, server: String, identifier: String, password: String) async -> Bool {
        sessionSubject.value = .loggingIn
        statusSubject.value = nil
        switch await client.login(backend: backend, server: server, identifier: identifier, password: password) {
        case .success(let token):
            sessions.save(PersistedSession(backend: backend, server: server, token: token))
            sessionSubject.value = .loggedIn
            await client.start()
            return true
        case .failure(let message):
            sessionSubject.value = .loggedOut
            statusSubject.value = message
            return false
        }
    }

    /// The deliberate sign-out. Local teardown is immediate — the client revokes
    /// server-side in the background — so the bounce to sign-in never waits on the network.
    ///
    /// The device token goes with it: this phone must stop receiving the departing user's
    /// DMs. Handed to the client rather than deregistered here, because it has to happen
    /// against the session being revoked and therefore before the revoke lands (#490).
    public func logout() {
        cancelReconnect()
        client.logout(deviceToken: deviceToken)
        deviceToken = nil
        // The next sign-in may be against a different server, whose answer differs.
        apnsSupported = nil
        sessions.clear()
        // The next account's preferences are not this one's — and a privacy switch in
        // particular must not carry across users. Both this and the deliberate sign-out clear
        // it, because either can be followed by someone else signing in on this phone.
        settingsCache.clear()
        store.reset()
        loadingOlder.removeAll()
        loadingNewer.removeAll()
        lastMarked.removeAll()
        statusSubject.value = nil
        sessionSubject.value = .loggedOut
    }

    // MARK: - Push (#490)

    /// This install's APNs device token, once the OS has issued one. Held so sign-out can
    /// deregister it, and so a re-register after reconnect doesn't need the app layer to
    /// remember.
    private var deviceToken: String?

    /// Cached answer to "does this server speak APNs". Fixed for a given server, and the
    /// question is asked on every activation — without this that's an HTTP round trip every
    /// time the user opens the app, to re-learn something that cannot have changed.
    /// Only a real answer is cached: a failed ask stays unknown and is retried.
    private var apnsSupported: Bool?

    /// Does this server speak APNs at all? A self-hosted server holds no Apple key and
    /// says so via `/api/push/config`, in which case asking the user for notification
    /// permission would be a lie — we'd get the grant and never deliver anything.
    ///
    /// `nil` means we couldn't ask. Deliberately NOT folded into `false`: the two are one
    /// wifi blip apart and would read identically at the call site, so collapsing them
    /// makes a transient failure report a permanent fact about the server's configuration
    /// — and sends whoever reads that line off auditing env vars on a box that was fine.
    /// Only a real answer is cached, so an unreachable server is asked again next time.
    public func serverSupportsAPNs() async -> Bool? {
        if let apnsSupported { return apnsSupported }
        guard let transports = await client.pushTransports() else { return nil }
        let supported = transports.contains("apns")
        apnsSupported = supported
        return supported
    }

    /// Hand the OS-issued device token to the server. Idempotent — iOS re-issues the same
    /// token on most launches, and the server upserts.
    @discardableResult
    public func registerPushDevice(token: String) async -> Bool {
        deviceToken = token
        guard session == .loggedIn else { return false }
        return await client.registerDevice(token: token)
    }

    /// Fill in a shell's contents — what a screen calls when it opens on a buffer we already
    /// hold but haven't fetched. A pure read; see `LurkerClient.loadLatest`.
    ///
    /// Deliberately the same request as `loadLatest(_:)` rather than a verb of its own. The
    /// server's `history` verb predates every version of the app, so hydration keeps working
    /// against an older self-hosted instance — which `protocol.ts` treats as a normal
    /// operating condition, since operators upgrade on their own schedule.
    public func hydrate(_ key: BufferKey) {
        // 200, not `loadLatest`'s default 100: this replaces what `open-buffer` used to
        // answer, and `buildBufferBacklog` ships 200. Taking the default would have quietly
        // halved every buffer's first screenful — the exact quantity `countBy` exists to
        // protect — and started the scroll-up pager a page sooner.
        client.loadLatest(
            networkId: key.networkId, target: key.target, countBy: historyCountBy, limit: 200
        )
    }

    /// Open a buffer for real: reopen, mint, or JOIN. Deliberate user intent only — this is a
    /// write, and the user's other devices are told about it. Filling in a shell is
    /// `hydrate(_:)`.
    public func openBuffer(_ key: BufferKey) {
        client.openBuffer(networkId: key.networkId, target: key.target, countBy: historyCountBy)
    }

    /// The page-size unit every history read asks for (#10). Read fresh each time rather than
    /// cached: `chat.consolidate_joins` is server-side, so it can change from the web mid-session
    /// and the next fetch should already agree with what the next render will do.
    private var historyCountBy: HistoryCountBy {
        HistoryCountBy.forRendering(store.state.settings)
    }

    /// Fetch a page of recent highlights (#13). `before` is the previous page's
    /// `nextBefore` cursor, nil for the first page. Returns nil on failure (a 401 also
    /// bounces the session); the caller renders an error state. This is a REST read that
    /// returns straight to the caller rather than folding into `state` — highlights span
    /// every buffer and are shown in their own list, not merged into any one buffer's log.
    public func fetchHighlights(before: Int? = nil) async -> HighlightsPage? {
        await client.fetchHighlights(before: before)
    }

    /// Fetch a page of bookmarks. Same cursor contract as `fetchHighlights`, and the
    /// same row shape — hence the shared `HighlightsPage`.
    ///
    /// Newest-first by *message* id: the order is when each line was said, not when it was
    /// saved. Bookmarking something from last spring files it under last spring.
    public func fetchBookmarks(before: Int? = nil) async -> HighlightsPage? {
        let page = await client.fetchBookmarks(before: before)
        // Every row in this feed is saved by definition, so fold the page into the id set:
        // it's the one place a bookmark whose buffer was never loaded can become known. Without
        // this, jumping from the list to the message would offer "Save Message" for something
        // already saved.
        //
        // One mutation, not one per row: `store.apply` publishes a whole `ChatState`, so a
        // page of `bookmark-updated` frames would wake every screen 50 times over to say one
        // thing.
        store.noteBookmarked(ids: (page?.items ?? []).map(\.message.id))
        return page
    }

    /// Run one page of a message search. `raw` is the user's whole input, filter grammar and
    /// all (`from:nick in:#channel on:network words`); `before` is the previous page's
    /// `nextBefore` cursor, nil for the first page.
    ///
    /// Returns nil for "couldn't ask or wasn't answered" and an empty page for "no matches" —
    /// the caller renders those differently, and collapsing them would let an offline search
    /// claim the user has never said the word they're looking for. A query with nothing to
    /// search on is neither: there is no question to ask, so it's an empty page.
    ///
    /// The `on:` token is resolved here rather than in the client because this is where the
    /// roster lives. A name that matches no network drops the filter instead of failing the
    /// search: `on:` is being typed a character at a time, and every prefix of a real network
    /// name would otherwise be a search that returns nothing.
    public func searchMessages(_ raw: String, before: Int? = nil) async -> HighlightsPage? {
        let query = SearchQuery.parse(raw)
        guard !query.isEmpty else { return HighlightsPage(items: [], nextBefore: nil) }
        // Lowest id wins, rather than whichever the dictionary happens to yield first. Two
        // networks can legitimately share a name — two connections to the same server, or two
        // user-named entries that collide — and `networks` is a dictionary, whose iteration
        // order is unspecified and free to differ between two calls. That's not merely untidy:
        // page one and page two of the SAME search are two calls, so an unstable pick would
        // append rows from a different network than the page they're extending.
        let networkId = query.network.isEmpty
            ? nil
            : store.state.networks.values
                .filter { $0.name.caseInsensitiveCompare(query.network) == .orderedSame }
                .min(by: { $0.id < $1.id })?.id
        let page = await client.search(query, networkId: networkId, before: before)
        // Search rows carry the same `bookmarked` flag as any other message row, and this is
        // the only place a saved line the user has never opened can become known — same
        // reasoning as `fetchBookmarks`, and the same single mutation rather than one per row.
        store.noteBookmarked(ids: (page?.items ?? []).filter(\.message.bookmarked).map(\.message.id))
        return page
    }

    /// Whether `messageId` is saved — what the message action sheet reads to decide between
    /// "Save Message" and "Remove Bookmark". See `ChatState.bookmarkedIds`.
    ///
    /// False for a saved message this session has never loaded. That's by design (the set is
    /// bounded by what's been seen) and is why callers that already *know* the answer — the
    /// Bookmarks list, where every row is saved — use `setBookmark` directly rather than
    /// toggling against this.
    public func isBookmarked(_ messageId: Int) -> Bool { state.isBookmarked(messageId) }

    /// Save or unsave a message outright.
    ///
    /// Deliberately sends and waits: the server fans a `bookmark-updated` back to every device,
    /// and a save it refuses (a message the account doesn't own) produces no echo at all — so
    /// flipping local state here would show a bookmark that doesn't exist.
    /// Returns false when the verb couldn't be put on the wire at all. Nothing retries it, so
    /// a caller that has already removed the row from a list must not treat that as done —
    /// see the Bookmarks list's swipe.
    @discardableResult
    public func setBookmark(messageId: Int, saved: Bool) -> Bool {
        client.setBookmark(messageId: messageId, saved: saved)
    }

    /// Upload a prepared file and return the stored object's URL for the composer to paste
    /// (#14). The caller has already picked the file and — for video — compressed it to fit
    /// the instance cap; this layer only speaks to the server. `onProgress` reports the
    /// device→server leg as a 0…1 fraction. UIKit-free by design: the picker and the video
    /// transcode live in the app target, so this package stays platform-light.
    public func upload(
        fileURL: URL,
        filename: String,
        mime: String,
        progressToken: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> Result<UploadResponse, UploadError> {
        do {
            let response = try await client.upload(
                fileURL: fileURL, filename: filename, mime: mime,
                progressToken: progressToken, onProgress: onProgress
            )
            return .success(response)
        } catch let error as UploadError {
            return .failure(error)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    /// What the UI should do after a line of input — almost always nothing, but `/msg` and
    /// `/query` ask the composer's owner to switch to the DM they opened, and `/join` asks
    /// it to switch once the channel actually exists.
    public enum SendOutcome: Equatable, Sendable {
        case none
        case activate(BufferKey)
        /// `/join` was sent. Switch to this buffer **when it materializes**, not now.
        ///
        /// Deliberately not `activate`: a join is a request the server can refuse (no such
        /// channel, +i, banned, or a 470 forward to a different name), and the buffer only
        /// exists once `channel-joined` comes back (§9.1). Switching immediately would put
        /// the user on a screen for a channel they may never be in, and — because nothing
        /// would ever arrive for it — one that sits on a loading spinner forever. So the
        /// UI waits for the row and navigates then; a refused join simply never fires,
        /// leaving the user where they typed with the error printed in front of them.
        case awaitJoin(BufferKey)
    }

    /// Handle a line of composer input from `key`'s buffer: a plain message goes to the
    /// current target; a slash command is parsed (`CommandParser`) and its effects carried
    /// out. Returns the UI follow-up, if any.
    @discardableResult
    public func send(_ key: BufferKey, text: String) -> SendOutcome {
        // The ignore rules go in because two commands read them: `/ignore` prints the listing
        // and `/unignore <n>` resolves a number against it. Handed to the parser rather than
        // fetched by it, so the whole command vocabulary stays pure and testable — this is the
        // only place that knows where the rules live. The set itself, not a listing built from
        // it: only those two verbs materialize one, and this runs on every line typed.
        switch CommandParser.parse(
            text,
            networkId: key.networkId,
            target: key.target,
            ignores: store.state.ignores
        ) {
        case .message(let body):
            client.sendMessage(networkId: key.networkId, target: key.target, text: body)
            return .none
        case .notCommand:
            // System-buffer input with no network to send to — the web's own nudge, rather
            // than dropping the one write the user made deliberately.
            store.appendLocal(key, text: "Not a command — type /commands to see what you can run here.")
            return .none
        case .command(let effects):
            return run(effects, in: key)
        }
    }

    /// Carry out a command's effects in order against `key`'s buffer, returning the last UI
    /// follow-up (an `activate`, for `/msg`). Wire effects run on `key`'s network; `away`/
    /// `back` are user-scoped and carry none; `info` prints a local line.
    private func run(_ effects: [CommandEffect], in key: BufferKey) -> SendOutcome {
        let networkId = key.networkId
        var outcome: SendOutcome = .none
        for effect in effects {
            switch effect {
            case .send(let target, let text):
                client.sendMessage(networkId: networkId, target: target, text: text)
            case .action(let target, let text):
                client.sendAction(networkId: networkId, target: target, text: text)
            case .notice(let target, let text):
                client.sendNotice(networkId: networkId, target: target, text: text)
            case .raw(let line):
                client.sendRaw(networkId: networkId, line: line)
            case .join(let channel, let joinKey):
                if let networkId {
                    client.joinChannel(networkId: networkId, channel: channel, key: joinKey)
                    outcome = .awaitJoin(BufferKey(networkId: networkId, target: channel))
                }
            case .part(let channel, let reason):
                client.part(networkId: networkId, channel: channel, reason: reason)
            case .close(let target):
                client.closeBuffer(networkId: networkId, target: target)
            case .away(let message):
                client.setAway(message)
            case .back:
                client.setBack()
            case .ctcp(let target, let type, let args):
                client.sendCTCP(networkId: networkId, target: target, issuingTarget: key.target, ctcpType: type, args: args)
            case .activate(let target):
                // Mint/hydrate the DM row so the buffer exists to switch to. A brand-new
                // /query target isn't in `state.buffers` yet, so the destination screen's own
                // hydrate wouldn't fire — this `open-buffer` is what brings the row (and its
                // backlog) into being.
                client.openBuffer(networkId: networkId, target: target, countBy: historyCountBy)
                outcome = .activate(BufferKey(networkId: networkId, target: target))
            case .addIgnore(let scope, let rule, let receipt):
                // `scope`, not `networkId`: nil is a global rule, which is the default and the
                // one an unqualified `/ignore bob` makes. Nothing is written locally — the
                // rule arrives on the server's `ignore-list-updated` fan-out, the same path a
                // rule made on the web takes to get here.
                report(client.addIgnore(networkId: scope, rule: rule), receipt, in: key)
            case .removeIgnore(let scope, let id, let mask, let receipt):
                report(client.removeIgnore(networkId: scope, id: id, mask: mask), receipt, in: key)
            case .info(let text):
                store.appendLocal(key, text: text)
            }
        }
        return outcome
    }

    /// Print a command's receipt, or say why there isn't one.
    ///
    /// `sent` is whether the verb reached a socket at all. Nothing queues these, so a false
    /// means it went nowhere and will not be retried — and a receipt printed anyway would be
    /// the app's own word for something that didn't happen. The failure line says what to do
    /// about it, which "failed" wouldn't.
    private func report(_ sent: Bool, _ receipt: String, in key: BufferKey) {
        store.appendLocal(
            key,
            text: sent ? receipt : "Not sent — you're not connected. Try again once you're back."
        )
    }

    /// Page older history for a buffer (scroll-up). Uses the oldest held message id as an
    /// exclusive cursor; no-ops if nothing older exists, nothing is held yet, or a page is
    /// already in flight.
    public func loadOlder(_ key: BufferKey) {
        guard !loadingOlder.contains(key.id),
              let buffer = store.state.buffers[key.id], buffer.hasMoreOlder,
              let oldest = store.state.messages[key.id]?.first(where: { $0.id != 0 })?.id
        else { return }
        loadingOlder.insert(key.id)
        client.loadOlder(networkId: key.networkId, target: key.target, before: oldest, countBy: historyCountBy)
    }

    /// Page newer history for a detached buffer (scroll-down, #45). Uses the newest held
    /// message id as an exclusive cursor; no-ops unless the buffer is detached (an `around`
    /// slice below the tail), something is held to page from, and no page is already in flight.
    /// The reply appends; reaching the tail (`hasMoreNewer: false`) re-attaches the buffer to
    /// live. This is how a jump-to-first-unread reader walks forward to the present.
    public func loadNewer(_ key: BufferKey) {
        guard !loadingNewer.contains(key.id),
              let buffer = store.state.buffers[key.id], buffer.hasMoreNewer,
              let newest = store.state.messages[key.id]?.last(where: { $0.id != 0 })?.id
        else { return }
        loadingNewer.insert(key.id)
        client.loadNewer(networkId: key.networkId, target: key.target, after: newest, countBy: historyCountBy)
    }

    /// Fetch a history slice centered on `anchorId` — the message a jump lands on (#42). The
    /// reply (`history` mode `around`) replaces the buffer's slice with the anchor in the
    /// middle; the screen scrolls to it once it lands. Distinct from `loadOlder`: this
    /// hydrates a buffer *around* a target rather than paging the tail, so it isn't gated on
    /// what's already held.
    public func loadAround(_ key: BufferKey, anchorId: Int) {
        client.loadAround(
            networkId: key.networkId, target: key.target, anchorId: anchorId, countBy: historyCountBy
        )
    }

    /// Re-attach a detached buffer to the live tail (#42) — the "return to live" a jump-to-
    /// latest tap makes after a jump parked the screen on an older `around` slice. The reply
    /// replaces the slice with the latest and clears the buffer's detached flag.
    public func loadLatest(_ key: BufferKey) {
        client.loadLatest(networkId: key.networkId, target: key.target, countBy: historyCountBy)
    }

    /// Mark a buffer read up to its latest loaded message. Server-authoritative and
    /// MAX-clamped, and deduped here, so calling it on every state change while viewing a
    /// buffer is cheap. The `read-state` echo updates the counts.
    public func markRead(_ key: BufferKey) {
        guard let latest = store.state.messages[key.id]?.compactMap({ $0.id != 0 ? $0.id : nil }).max(),
              latest > (lastMarked[key.id] ?? 0)
        else { return }
        lastMarked[key.id] = latest
        client.markRead(networkId: key.networkId, target: key.target, messageId: latest)
    }

    public func markAllRead() {
        client.markAllRead()
    }

    /// Emit a `typing` signal for `key`. Buffers with nobody on the other end — the system
    /// buffer, a `:server:` log — are dropped by the client, which owns that guard for every
    /// conversation-only verb (see `LurkerClient.setTyping`).
    ///
    /// Gated on `chat.send_typing_notifications` here rather than at the call site: this is a
    /// privacy switch, and a gate you have to remember to apply isn't one. The web enforces
    /// the same setting purely client-side (`MessageInput.vue:544`) — `ircManager.typing` does
    /// no gating of its own — so honoring it here is the whole mechanism, not half of one.
    public func setTyping(_ key: BufferKey, signal: TypingSignal) {
        guard store.state.settings.bool("chat.send_typing_notifications", default: true) else { return }
        client.setTyping(networkId: key.networkId, target: key.target, signal: signal)
    }

    /// Write settings (#65). The server validates, stores, and fans a `settings` frame back to
    /// every device — this one included — so the store updates from that echo rather than
    /// optimistically here: one path for "a setting changed", whatever caused it, and a
    /// rejected write simply never lands instead of needing to be rolled back.
    ///
    /// Returns the server's own error message on failure, nil on success.
    public func updateSettings(_ changes: [String: SettingValue]) async -> String? {
        await client.updateSettings(changes)
    }

    public func joinChannel(networkId: Int, channel: String) {
        let name = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        client.joinChannel(networkId: networkId, channel: name)
    }

    /// Close a buffer (part a channel / drop a DM) and remove its row immediately.
    public func closeBuffer(_ key: BufferKey) {
        client.closeBuffer(networkId: key.networkId, target: key.target)
        store.removeBuffer(key)
    }

    /// The networks the user is on, for the join picker and buffer-list grouping.
    public var networks: [Network] { Array(store.state.networks.values) }

    // MARK: - Friends (contacts)

    /// The friends list, sorted by display name. The UI reads presence live off `state`
    /// (`state.primaryPresence(contact)`), so this is just identity + targets.
    public var contacts: [Contact] { store.state.contacts }

    /// Create (nil `id`) or edit a friend. The optimistic UI comes from the server's
    /// `contact-updated` echo, which folds in via the normal frame path — no local mutation.
    public func saveContact(id: Int?, displayName: String, notifyOnline: Bool, targets: [ContactTarget]) {
        client.setContact(id: id, displayName: displayName, notifyOnline: notifyOnline, targets: targets)
    }

    /// Remove a friend. The list updates when the `contact-deleted` echo lands.
    public func deleteContact(id: Int) {
        client.deleteContact(id: id)
    }

    public func clearError() { store.clearError() }

    // MARK: - App lifecycle (fed by the SceneDelegate)

    /// Back on screen: a socket that died in the background often hasn't fired its failure
    /// yet (the connection is suspended while backgrounded), so the status can still read
    /// Connected over a dead socket. Reconnect if we're disconnected OR were backgrounded
    /// long enough that the socket may be stale; a brief app-switch leaves a healthy
    /// socket alone.
    public func enterForeground() {
        isForeground = true
        guard session == .loggedIn else { return }
        // Tell the server we're looking, so it stops pushing (#490). Sent before the
        // reconnect check below because the common case is a LIVE socket — we're back and
        // nothing needs reopening — and that path returns early. A new socket re-asserts
        // presence itself, so sending here too is at worst a duplicate the server folds.
        client.setPresence(true)
        let stale = backgroundedAt.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? false
        if store.state.connection == .connected, !stale { return }
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        doReconnect(force: true)
    }

    /// `onFlush` fires once the presence frame is on the wire — the app holds a
    /// background-task assertion until then, because this frame is sent in the one window
    /// where iOS is actively trying to suspend us. Always called, including when there was
    /// nothing to send, so the caller can't leak the assertion.
    public func enterBackground(onFlush: (@Sendable () -> Void)? = nil) {
        isForeground = false
        backgroundedAt = Date()
        // The moment that makes push work: until the server hears this it believes a
        // client is watching and suppresses every notification. The socket usually
        // survives backgrounding for a while, so waiting for it to drop would mean up to
        // ~60s of silence (the server pings every 30s and reaps on the second miss).
        //
        // Not covered here: a force-quit or a tunnel, where nothing gets sent and that
        // reaper IS the backstop. That gap is real and known — see #490.
        guard session == .loggedIn else {
            onFlush?()
            return
        }
        client.setPresence(false, onFlush: onFlush)
    }

    /// The OS's network path came or went. Fed in from the app (which owns the
    /// `NWPathMonitor`) for the same reason foreground/background is — it keeps this
    /// package off the `Network` framework, whose `NWPath` types would also have to share
    /// a namespace with our own `Network` model.
    ///
    /// Regaining a path also short-circuits the backoff: the reason we were waiting just
    /// went away, and a user who reconnects to wifi shouldn't watch a 30s timer run down.
    public func setReachable(_ reachable: Bool) {
        let was = store.state.reachable
        store.setReachable(reachable)
        guard reachable, !was, session == .loggedIn, isForeground else { return }
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        doReconnect(force: false)
    }

    // MARK: - Session restore

    /// On launch, re-arm from a Keychain-persisted session if one exists. Optimistic: go
    /// `loggedIn` before connecting, so a stale token's 401 (fired during `start()`) lands
    /// afterward and deterministically wins the bounce back to sign-in rather than racing a
    /// `loggedIn` that arrives later.
    private func restoreSession() {
        guard let saved = sessions.load() else {
            sessionSubject.value = .loggedOut
            return
        }
        // A session persisted before the transport policy (#29) can name a server the
        // policy now rejects — a non-local http:// address the old blanket ATS exemption
        // allowed. Restoring it would go loggedIn and then spin ATS-blocked reconnects
        // forever. Bounce to sign-in with the same copy login would give, and drop the
        // session: its token belongs to a server we can no longer talk to. The server
        // field still prefills from preferences, so the address stays visible to fix.
        if let reason = ServerAddress.rejection(of: ServerAddress.normalize(saved.server)) {
            sessions.clear()
            statusSubject.value = reason
            sessionSubject.value = .loggedOut
            return
        }
        sessionSubject.value = .loggedIn
        client.restore(server: saved.server, token: saved.token)
        Task { await client.start() }
    }

    // MARK: - Frame routing

    private func handle(_ frame: ServerFrame) {
        switch frame {
        case .settingsBootstrap, .settingsChanged, .settingsValues:
            store.apply(frame)
            // Persist after folding, not from the frame: a `settingsChanged` patch carries only
            // what moved, so the cache has to mirror the merged result rather than the delta.
            settingsCache.save(store.state.settings.values)
        case .unauthorized:
            onAuthLost()
        case .socketOpen:
            store.apply(frame)
            reconnectAttempt = 0 // a clean connection resets the backoff
        case .socketClosed:
            loadingOlder.removeAll() // in-flight history pages won't get a reply now
            loadingNewer.removeAll()
            store.apply(frame)
            onSocketDropped()
        case .history(let networkId, let target, _, let mode, _, _):
            // The page in flight is done — clear the set that requested this mode so the next
            // scroll can page again. Only `before` arms `loadingOlder` and only `after` arms
            // `loadingNewer`; `around`/`latest` are one-shots tracked by the screen, not here.
            let id = BufferKey(networkId: networkId, target: target).id
            switch mode {
            case .before: loadingOlder.remove(id)
            case .after: loadingNewer.remove(id)
            case .around, .latest: break
            }
            store.apply(frame)
        default:
            store.apply(frame)
        }
    }

    // MARK: - Reconnect

    /// A drop while signed-in + foregrounded schedules a backed-off reconnect.
    private func onSocketDropped() {
        guard session == .loggedIn, isForeground else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return } // one attempt already in flight
        let wait = backoff(reconnectAttempt)
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.doReconnect(force: false)
        }
    }

    /// The single reconnect path. `force` reconnects even when the status reads Connected
    /// (the stale-socket case); otherwise a scheduled attempt bails if the connection came
    /// back meanwhile, so a pending timer can't tear down a good socket.
    private func doReconnect(force: Bool) {
        guard session == .loggedIn, isForeground else { return }
        if !force, store.state.connection == .connected { return }
        client.reconnect(since: store.state.maxEventId)
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
    }

    /// The token expired or was revoked elsewhere. Drop the (already-dead) session without
    /// a revoke round-trip and bounce to sign-in with an explanation.
    private func onAuthLost() {
        guard session != .loggedOut else { return } // handle the first 401, ignore the rest
        cancelReconnect()
        client.close()
        sessions.clear()
        // The next account's preferences are not this one's — and a privacy switch in
        // particular must not carry across users. Both this and the deliberate sign-out clear
        // it, because either can be followed by someone else signing in on this phone.
        settingsCache.clear()
        store.reset()
        loadingOlder.removeAll()
        loadingNewer.removeAll()
        lastMarked.removeAll()
        statusSubject.value = "Your session ended — please sign in again."
        sessionSubject.value = .loggedOut
    }

    /// 1s, 2s, 4s … capped at 30s.
    private func backoff(_ attempt: Int) -> Double {
        min(Self.baseBackoff * pow(2, Double(min(attempt, Self.maxShift))), Self.maxBackoff)
    }

    private static let baseBackoff: Double = 1
    private static let maxBackoff: Double = 30
    private static let maxShift = 5 // 1s << 5 = 32s, clamped to 30s
    private static let staleAfter: TimeInterval = 30
}
