// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// IRCv3 metadata display names and avatars (lurker#607, Mobile lurker#1203): the frames, the
/// store, the tile hash and the set pointer.
@MainActor
final class MetadataAndAvatarsTests: XCTestCase {

    // MARK: - Parser

    func testSnapshotSeedsUserMetadataAndLimits() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":2,"state":"connected","nick":"me","channels":[],"userMetadata":{"alice":{"displayName":"\u000304Alice\u0003","avatarUrl":"/api/link-preview/avatar/abc","pronouns":"she/her","homepage":"https://a.example","status":"busy"},"bob":{"avatarUrl":null}},"metadataLimits":{"maxSubs":10,"maxKeys":20,"maxValueBytes":300,"beforeConnect":true}}]}"##
        )
        guard case let .snapshot(networks, _, _, _) = frame else { return XCTFail("expected snapshot, got \(frame)") }
        let net = networks[0]
        XCTAssertEqual(net.userMetadata.count, 2)
        XCTAssertEqual(net.userMetadata["alice"]?.displayName, "\u{03}04Alice\u{03}")
        XCTAssertEqual(net.userMetadata["alice"]?.avatarUrl, "/api/link-preview/avatar/abc")
        XCTAssertEqual(net.userMetadata["alice"]?.pronouns, "she/her")
        XCTAssertEqual(net.userMetadata["alice"]?.homepage, "https://a.example")
        XCTAssertEqual(net.userMetadata["alice"]?.status, "busy")
        // A null avatar is nil: the server can't serve one, so the generated tile stands in.
        XCTAssertNil(net.userMetadata["bob"]?.avatarUrl)
        XCTAssertEqual(net.userMetadata["bob"]?.isEmpty, true)
        XCTAssertEqual(net.metadataLimits, MetadataLimits(maxSubs: 10, maxKeys: 20, maxValueBytes: 300, beforeConnect: true))
    }

    func testSnapshotWithoutMetadataIsAnOlderServer() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":2,"state":"connected","nick":"me","channels":[]}]}"##
        )
        guard case let .snapshot(networks, _, _, _) = frame else { return XCTFail("expected snapshot, got \(frame)") }
        XCTAssertTrue(networks[0].userMetadata.isEmpty)
        XCTAssertNil(networks[0].metadataLimits)
    }

    func testNullLimitsIsANetworkWithoutMetadata() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":2,"state":"connected","nick":"me","channels":[],"metadataLimits":null}]}"##
        )
        guard case let .snapshot(networks, _, _, _) = frame else { return XCTFail("expected snapshot, got \(frame)") }
        XCTAssertNil(networks[0].metadataLimits)
    }

    func testUserMetadataRidesIrcWithServerTarget() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":2,"target":":server:2","type":"user-metadata","nick":"Alice","values":{"displayName":"Wonderland Alice","avatarUrl":null}}"##
        )
        guard case let .userMetadata(networkId, nick, values) = frame else {
            return XCTFail("expected userMetadata, got \(frame)")
        }
        XCTAssertEqual(networkId, 2)
        XCTAssertEqual(nick, "Alice")
        XCTAssertEqual(values?.displayName, "Wonderland Alice")
        XCTAssertNil(values?.avatarUrl)
    }

    func testUserMetadataWithNullValuesForgetsTheNick() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":2,"target":":server:2","type":"user-metadata","nick":"alice","values":null}"##
        )
        guard case let .userMetadata(_, _, values) = frame else { return XCTFail("expected userMetadata, got \(frame)") }
        XCTAssertNil(values)
    }

    func testUserMetadataWithoutNetworkOrNickIsIgnored() {
        for text in [
            ##"{"kind":"irc","target":":server:2","type":"user-metadata","nick":"alice","values":{}}"##,
            ##"{"kind":"irc","networkId":2,"target":":server:2","type":"user-metadata","values":{}}"##,
        ] {
            let frame = FrameParser.parseWs(text)
            guard case .ignored = frame else { return XCTFail("expected ignored, got \(frame)") }
        }
    }

    /// ⚠ The regression this whole seam guards: left to fall through, both metadata events became
    /// `.other` lines — an empty row in the server buffer on every profile change, and a channel
    /// row's worth of nothing on a channel-metadata.
    func testMetadataEventsNeverBecomeALine() {
        let store = LurkerStore()
        store.apply(.socketOpen)
        store.apply(.snapshot(
            [NetworkSnapshot(id: 2, state: .connected, nick: "me", channels: [
                ChannelSnapshot(name: "#lurker", topic: nil, members: []),
            ])],
            globalIgnores: [], uploadLimits: .unstated
        ))
        let before = store.state.messages.mapValues(\.count)
        store.apply(FrameParser.parseWs(
            ##"{"kind":"irc","networkId":2,"target":":server:2","type":"user-metadata","nick":"alice","values":{"displayName":"A"}}"##
        ))
        let channel = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":2,"target":"#lurker","type":"channel-metadata","values":{"displayName":"The Lurkers","avatarUrl":null}}"##
        )
        guard case .ignored = channel else { return XCTFail("channel-metadata should be ignored, got \(channel)") }
        store.apply(channel)
        XCTAssertEqual(store.state.messages.mapValues(\.count), before, "no row anywhere")
        XCTAssertEqual(store.state.metadata(networkId: 2, nick: "alice")?.displayName, "A")
    }

    func testAvatarSetsChangedIsItsOwnFrame() {
        let frame = FrameParser.parseWs(##"{"kind":"avatar-sets-changed"}"##)
        guard case .avatarSetsChanged = frame else { return XCTFail("expected avatarSetsChanged, got \(frame)") }
    }

    // MARK: - Store

    private func network(_ id: Int, metadata: [String: UserMetadata] = [:], limits: MetadataLimits? = nil) -> NetworkSnapshot {
        var snapshot = NetworkSnapshot(id: id, state: .connected, nick: "me", channels: [])
        snapshot.userMetadata = metadata
        snapshot.metadataLimits = limits
        return snapshot
    }

    private func snapshot(_ networks: NetworkSnapshot...) -> ServerFrame {
        .snapshot(networks, globalIgnores: [], uploadLimits: .unstated)
    }

    func testLiveMetadataReplacesWholeAndNullForgets() {
        let store = LurkerStore()
        store.apply(snapshot(network(2, metadata: ["alice": UserMetadata(displayName: "A", pronouns: "she")])))
        // Whole record: a frame without pronouns is a record without pronouns.
        store.apply(.userMetadata(networkId: 2, nick: "Alice", values: UserMetadata(displayName: "B")))
        XCTAssertEqual(store.state.metadata(networkId: 2, nick: "ALICE")?.displayName, "B")
        XCTAssertNil(store.state.metadata(networkId: 2, nick: "alice")?.pronouns)
        store.apply(.userMetadata(networkId: 2, nick: "alice", values: nil))
        XCTAssertNil(store.state.metadata(networkId: 2, nick: "alice"))
        XCTAssertEqual(store.state.userMetadata.count(networkId: 2), 0)
        // The patch path folds its one key like the seed folds all of them.
        store.apply(.userMetadata(networkId: 2, nick: "ΟΔΥΣΣΕΥΣ", values: UserMetadata(status: "x")))
        XCTAssertEqual(store.state.metadata(networkId: 2, nick: "οδυσσευς")?.status, "x")
    }

    func testMetadataIsPerNetworkAndSnapshotReplacesWholesale() {
        let store = LurkerStore()
        store.apply(snapshot(
            network(2, metadata: ["alice": UserMetadata(displayName: "Two"), "bob": UserMetadata(status: "x")]),
            network(3, metadata: ["alice": UserMetadata(displayName: "Three")])
        ))
        XCTAssertEqual(store.state.metadata(networkId: 2, nick: "alice")?.displayName, "Two")
        XCTAssertEqual(store.state.metadata(networkId: 3, nick: "alice")?.displayName, "Three")
        XCTAssertNil(store.state.metadata(networkId: nil, nick: "alice"))
        store.apply(snapshot(network(2, metadata: ["alice": UserMetadata(displayName: "Two")])))
        XCTAssertNil(store.state.metadata(networkId: 2, nick: "bob"), "a reconnect's snapshot is the whole map")
    }

    func testMetadataKeysFoldLikeTheWeb() {
        // The server keys with JavaScript's toLowerCase(), which lowers a final capital sigma to ς;
        // a lookup here has to land on the same key (lurker-ios#199 for the colour).
        let store = LurkerStore()
        store.apply(snapshot(network(2, metadata: ["οδυσσευς": UserMetadata(displayName: "O")])))
        XCTAssertEqual(store.state.metadata(networkId: 2, nick: "ΟΔΥΣΣΕΥΣ")?.displayName, "O")
    }

    func testMetadataSetIsReplacedNotMutated() {
        let store = LurkerStore()
        store.apply(snapshot(network(2)))
        let before = store.state.userMetadata
        store.apply(.userMetadata(networkId: 2, nick: "alice", values: UserMetadata(displayName: "A")))
        XCTAssertFalse(before === store.state.userMetadata)
        let after = store.state.userMetadata
        store.apply(.avatarSetsChanged)
        XCTAssertTrue(after === store.state.userMetadata, "a frame that changes nothing keeps the pointer")
    }

    func testDroppingANetworkDropsItsMetadataAndLimits() {
        let store = LurkerStore()
        let limits = MetadataLimits(maxSubs: 1, maxKeys: 1, maxValueBytes: 1, beforeConnect: false)
        store.apply(snapshot(network(2, metadata: ["alice": UserMetadata(displayName: "A")], limits: limits)))
        XCTAssertEqual(store.state.networks[2]?.metadataLimits, limits)
        // A roster that no longer names the network drops it, metadata and all.
        store.apply(.networks([Network(id: 3, name: "Other")]))
        XCTAssertNil(store.state.metadata(networkId: 2, nick: "alice"))
        XCTAssertEqual(store.state.userMetadata.count(networkId: 2), 0)
    }

    func testLimitsClearWhenTheLinkDropsLikeModeSpec() {
        let store = LurkerStore()
        let limits = MetadataLimits(maxSubs: 1, maxKeys: 1, maxValueBytes: 1, beforeConnect: false)
        store.apply(snapshot(network(2, limits: limits)))
        store.apply(.networkState(networkId: 2, state: .disconnected, nick: nil))
        XCTAssertNil(store.state.networks[2]?.metadataLimits)
    }

    // MARK: - Display names

    private func storeWith(settings values: [String: SettingValue], metadata: [String: UserMetadata]) -> LurkerStore {
        let store = LurkerStore()
        store.apply(.settingsBootstrap(registry: [:], values: values))
        store.apply(snapshot(network(2, metadata: metadata)))
        return store
    }

    func testDisplayNameShowsRawAndPlainAndKeepsTheNickAsIdentity() {
        let store = storeWith(settings: [:], metadata: ["alice": UserMetadata(displayName: " \u{03}04Wonderland\u{03} Alice ")])
        XCTAssertEqual(store.state.displayName(networkId: 2, nick: "Alice"), " \u{03}04Wonderland\u{03} Alice ")
        XCTAssertEqual(store.state.plainDisplayName(networkId: 2, nick: "alice"), "Wonderland Alice")
        XCTAssertEqual(store.state.label(networkId: 2, nick: "alice"), "Wonderland Alice")
        XCTAssertEqual(store.state.label(networkId: 2, nick: "bob"), "bob")
        XCTAssertNil(store.state.displayName(networkId: 3, nick: "alice"))
    }

    func testANameThatStripsToNothingIsNoName() {
        let store = storeWith(settings: [:], metadata: [
            "alice": UserMetadata(displayName: "\u{03}04\u{03}  "),
            "bob": UserMetadata(displayName: ""),
            "carol": UserMetadata(pronouns: "they"),
        ])
        for nick in ["alice", "bob", "carol"] {
            XCTAssertNil(store.state.displayName(networkId: 2, nick: nick), nick)
            XCTAssertEqual(store.state.label(networkId: 2, nick: nick), nick)
        }
    }

    func testTheSettingOffPrintsNicksEverywhereButKeepsTheRecord() {
        let store = storeWith(
            settings: [ChatState.displayNamesKey: .bool(false)],
            metadata: ["alice": UserMetadata(displayName: "Wonderland", pronouns: "she")]
        )
        XCTAssertNil(store.state.displayName(networkId: 2, nick: "alice"))
        XCTAssertEqual(store.state.label(networkId: 2, nick: "alice"), "alice")
        XCTAssertEqual(store.state.metadata(networkId: 2, nick: "alice")?.pronouns, "she", "the profile still reads it")
    }

    // MARK: - Tiles

    func testTileIndexMatchesTheWebsVectors() {
        // Computed from shared/avatarTiles.ts (node) — every client must agree.
        let vectors: [(String, Int, Int)] = [
            ("bob", 140, 4), ("Bob", 140, 4), ("bob_", 140, 4), ("bob|away", 140, 4), ("_bob", 140, 70),
            ("alice", 140, 11), ("amiantos", 140, 138), ("ñandú", 140, 71), ("[bracket]", 140, 94),
            ("Σίσυφος", 140, 94), ("ΟΔΥΣΣΕΥΣ", 140, 44), ("🙂face", 140, 75),
            ("bob", 7, 4), ("bob", 1, 0), ("_", 10, 2),
            ("a", 100, 64), ("Zed", 100, 23), ("someone_long_nick", 100, 14),
        ]
        for (nick, count, expected) in vectors {
            XCTAssertEqual(AvatarTiles.index(for: nick, count: count), expected, "\(nick) in \(count)")
        }
        XCTAssertEqual(AvatarTiles.index(for: "bob-x", count: 140, stopChars: ["-"]), 4)
    }

    func testTileIndexIsDeterministicInsideTheSetAndSpreads() {
        for nick in ["a", "Zed", "someone_long_nick", "ñandú", "[bracket]"] {
            let i = AvatarTiles.index(for: nick, count: 7)
            XCTAssertNotNil(i)
            XCTAssertTrue((0..<7).contains(i ?? -1), nick)
            XCTAssertEqual(i, AvatarTiles.index(for: nick, count: 7))
        }
        var seen = Set<Int>()
        for i in 0..<400 { seen.insert(AvatarTiles.index(for: "nick\(i)", count: 32) ?? -1) }
        XCTAssertEqual(seen.count, 32)
    }

    func testTileIndexAnswersNilWhenThereIsNothingToPick() {
        XCTAssertNil(AvatarTiles.index(for: "", count: 10))
        XCTAssertNil(AvatarTiles.index(for: nil, count: 10))
        XCTAssertNil(AvatarTiles.index(for: "bob", count: 0))
        // A nick that is all stop characters keeps them, as the colour does.
        XCTAssertNotNil(AvatarTiles.index(for: "_", count: 10))
    }

    func testTileUrlNumbersFrom000() {
        XCTAssertEqual(AvatarTiles.url(base: "/avatars/ealain", index: 0, ext: "webp"), "/avatars/ealain/000.webp")
        XCTAssertEqual(AvatarTiles.url(base: "/avatars/ealain/", index: 42, ext: "png"), "/avatars/ealain/042.png")
        XCTAssertEqual(AvatarTiles.url(base: "/api/avatar-sets/7", index: 123, ext: "webp"), "/api/avatar-sets/7/123.webp")
    }

    // MARK: - Sets

    private func settings(_ values: [String: SettingValue]) -> Settings {
        Settings(registry: [:], values: values)
    }

    func testThePointerResolvesAndADanglingOneFallsBackToInitial() {
        var sets = AvatarSets()
        XCTAssertEqual(sets.active(settings: settings([:])).id, "initial")
        XCTAssertEqual(sets.active(settings: settings([AvatarSets.settingKey: .string("plain")])).id, "plain")
        XCTAssertEqual(sets.active(settings: settings([AvatarSets.settingKey: .string("7")])).id, "initial", "unfetched upload")
        XCTAssertEqual(sets.active(settings: settings([AvatarSets.settingKey: .string("nope")])).id, "initial")
        sets.uploaded = [UploadedAvatarSet(id: 7, name: "Cats", count: 12)]
        let active = sets.active(settings: settings([AvatarSets.settingKey: .string("7")]))
        XCTAssertEqual(active.name, "Cats")
        XCTAssertEqual(active.kind, .tiles(.init(baseUrl: "/api/avatar-sets/7", count: 12, ext: "webp")))
        XCTAssertFalse(active.builtin)
    }

    /// A server from before its schema v28 still stores the ids Initial and Plain had while each
    /// came in two inks. They mean the set they became, not "unknown, so the default".
    func testAnIdFromBeforeTheInkWasAutomaticMeansTheSetItBecame() {
        let sets = AvatarSets()
        for (old, now) in [("initial-light", "initial"), ("initial-dark", "initial"), ("plain-light", "plain"), ("plain-dark", "plain")] {
            XCTAssertEqual(AvatarSets.currentSetId(old), now)
            XCTAssertEqual(sets.active(settings: settings([AvatarSets.settingKey: .string(old)])).id, now)
            XCTAssertEqual(sets.set(id: old)?.id, now)
        }
        for id in ["ealain", "initial", "plain", "7", "nope"] {
            XCTAssertEqual(AvatarSets.currentSetId(id), id)
        }
    }

    /// The other direction: that server's web client knows no `plain` or `initial`, so a pick
    /// made here is written under the id it does know.
    func testAPickIsWrittenUnderTheIdTheServerKnows() {
        func server(default id: String) -> Settings {
            let option = SettingOption(
                key: AvatarSets.settingKey, label: "Set", description: "", type: .string, default: .string(id)
            )
            return Settings(registry: [AvatarSets.settingKey: option], values: [:])
        }
        let old = server(default: "initial-dark")
        XCTAssertEqual(AvatarSets.storedSetId("plain", settings: old), "plain-dark")
        XCTAssertEqual(AvatarSets.storedSetId("initial", settings: old), "initial-dark")
        XCTAssertEqual(AvatarSets.storedSetId("ealain", settings: old), "ealain")
        XCTAssertEqual(AvatarSets.storedSetId("7", settings: old), "7")
        // Whatever is written reads back as the set that was picked.
        for id in ["plain", "initial", "ealain"] {
            XCTAssertEqual(AvatarSets.currentSetId(AvatarSets.storedSetId(id, settings: old)), id)
        }
        let current = server(default: "initial")
        for id in ["plain", "initial", "ealain", "7"] {
            XCTAssertEqual(AvatarSets.storedSetId(id, settings: current), id)
            XCTAssertEqual(AvatarSets.storedSetId(id, settings: settings([:])), id, "no registry yet")
        }
    }

    func testTilePathNeedsAManifestAndAnInitialSetHasNone() {
        var sets = AvatarSets()
        let ealain = settings([AvatarSets.settingKey: .string("ealain")])
        XCTAssertNil(sets.tilePath(for: "bob", settings: ealain, ink: .dark), "no manifest yet: colour only")
        sets.manifests["ealain"] = AvatarSetManifest(count: 140)
        XCTAssertEqual(sets.tilePath(for: "bob", settings: ealain, ink: .dark), "/avatars/ealain/004.webp")
        XCTAssertEqual(sets.tilePath(for: "bob", settings: ealain, ink: .light), "/avatars/ealain/004.webp", "art has one ink")
        XCTAssertNil(sets.tilePath(for: "bob", settings: settings([:]), ink: .dark), "Initial draws a letter")
        // The stop chars follow the colour's setting.
        let dash = settings([AvatarSets.settingKey: .string("ealain"), "look.nick.color_stop_chars": .string("-")])
        XCTAssertEqual(sets.tilePath(for: "bob-x", settings: dash, ink: .dark), "/avatars/ealain/004.webp")
    }

    func testAPlainSetTakesItsSilhouetteFromTheDirectoryOfTheInk() {
        var sets = AvatarSets()
        let plain = settings([AvatarSets.settingKey: .string("plain")])
        XCTAssertNil(sets.tilePath(for: "bob", settings: plain, ink: .light), "no manifest yet")
        // Each directory is counted by its own manifest, as the web counts them: one that has
        // not been read draws colour only, whatever the other says.
        sets.manifests["plain-light"] = AvatarSetManifest(count: 1)
        XCTAssertEqual(sets.tilePath(for: "bob", settings: plain, ink: .light), "/avatars/plain-light/000.webp")
        XCTAssertNil(sets.tilePath(for: "bob", settings: plain, ink: .dark))
        sets.manifests["plain-dark"] = AvatarSetManifest(count: 1, ext: "png")
        XCTAssertEqual(sets.tilePath(for: "bob", settings: plain, ink: .light), "/avatars/plain-light/000.webp")
        XCTAssertEqual(sets.tilePath(for: "bob", settings: plain, ink: .dark), "/avatars/plain-dark/000.png")
        XCTAssertEqual(sets.active(settings: plain).tileCount, 1)
    }

    func testInkFollowsTheLuminanceOfTheColourUnderIt() {
        func ink(_ hex: UInt32) -> AvatarInk {
            AvatarInk.on(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
        }
        XCTAssertEqual(ink(0xffffff), .dark)
        XCTAssertEqual(ink(0x000000), .light)
        // Both built-in nick palettes, whole: the dark theme's pastels take dark ink, the light
        // theme's deeper hues light. A palette edit that crosses the line fails here.
        func hex(_ string: String) -> UInt32 { UInt32(string.dropFirst(), radix: 16)! }
        for colour in IRCPalette.nick { XCTAssertEqual(ink(hex(colour)), .dark, colour) }
        for colour in IRCPalette.nickLight { XCTAssertEqual(ink(hex(colour)), .light, colour) }
        // The muted greys under a server line's mark (the app's Palette.fgMuted), dark and light.
        XCTAssertEqual(ink(0x939293), .dark)
        XCTAssertEqual(ink(0x706b6e), .light)
        XCTAssertEqual(AvatarInk.luminanceThreshold, 0.28)
        XCTAssertEqual(AvatarInk.relativeLuminance(red: 1, green: 1, blue: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(AvatarInk.relativeLuminance(red: 0, green: 0, blue: 0), 0, accuracy: 1e-9)
        // The line itself: above it dark, at or below it light. Greys either side, by search.
        var below = 0
        while AvatarInk.relativeLuminance(red: Double(below + 1) / 255, green: Double(below + 1) / 255, blue: Double(below + 1) / 255) <= AvatarInk.luminanceThreshold {
            below += 1
        }
        let grey = { (v: Int) in AvatarInk.on(red: Double(v) / 255, green: Double(v) / 255, blue: Double(v) / 255) }
        XCTAssertEqual(grey(below), .light)
        XCTAssertEqual(grey(below + 1), .dark)
        // Out-of-gamut channels (extended sRGB) clamp rather than poison the sum.
        XCTAssertEqual(AvatarInk.on(red: 1.2, green: 1.1, blue: -0.1), .dark)
    }

    func testListAndManifestDecode() {
        let list = AvatarSets.parseList(Data(##"{"items":[{"id":7,"name":"Cats","count":12,"bytes":1,"createdAt":"x"},{"name":"no id"}]}"##.utf8))
        XCTAssertEqual(list, [UploadedAvatarSet(id: 7, name: "Cats", count: 12)])
        XCTAssertNil(AvatarSets.parseList(Data(##"{"nope":true}"##.utf8)), "wrong shape keeps what we had")
        XCTAssertEqual(AvatarSets.parseManifest(Data(##"{"count":140,"ext":"webp"}"##.utf8)), AvatarSetManifest(count: 140, ext: "webp"))
        XCTAssertEqual(AvatarSets.parseManifest(Data(##"{"count":1}"##.utf8)), AvatarSetManifest(count: 1, ext: "webp"))
        XCTAssertNil(AvatarSets.parseManifest(Data(##"{"count":0}"##.utf8)))
        XCTAssertNil(AvatarSets.parseManifest(Data(##"{"count":"many"}"##.utf8)))
    }

    func testBuiltinsMatchTheWeb() {
        XCTAssertEqual(AvatarSets.builtins.map(\.id), ["ealain", "plain", "initial"])
        XCTAssertEqual(AvatarSets.builtins.map(\.name), ["Ealain", "Plain", "Initial"])
        XCTAssertEqual(AvatarSets.builtinManifestDirs, ["ealain", "plain-light", "plain-dark"])
        XCTAssertEqual(AvatarSets.defaultSetId, "initial")
    }

    // MARK: - Density

    func testTheGutterIsTheIndentOnlyWhereItIsDrawn() {
        // The setting reads as stored whatever the avatar switch says — the feed shares it and
        // draws no gutter; the list takes `flushBodies` where it draws the column.
        let density = CompactDensity(settings: settings([CompactDensity.indentKey: .int(4), CompactDensity.avatarsKey: .bool(true)]))
        XCTAssertEqual(density.indent, 4)
        XCTAssertEqual(density.flushBodies, CompactDensity(groupGap: 10, lineHeightPercent: 155, indent: 0))
        XCTAssertTrue(CompactDensity.avatarsOn(settings([CompactDensity.avatarsKey: .bool(true)])))
        XCTAssertFalse(CompactDensity.avatarsOn(settings([:])))
    }

    func testASetAnswersTilePathsOnItsOwn() {
        var sets = AvatarSets()
        sets.manifests["ealain"] = AvatarSetManifest(count: 140)
        let active = sets.active(settings: settings([AvatarSets.settingKey: .string("ealain")]))
        XCTAssertEqual(active.tilePath(for: "bob", stopChars: AvatarTiles.defaultStopChars, ink: .dark), "/avatars/ealain/004.webp")
        XCTAssertEqual(active.tilePath(for: "bob-x", stopChars: ["-"], ink: .dark), "/avatars/ealain/004.webp")
        XCTAssertNil(active.tilePath(for: nil, stopChars: [], ink: .dark))
        XCTAssertNil(sets.active(settings: settings([:])).tilePath(for: "bob", stopChars: [], ink: .dark), "an Initial set draws a letter")
        XCTAssertEqual(AvatarSets.stopChars(settings: settings(["look.nick.color_stop_chars": .string("-")])), ["-"])
    }

    // MARK: - Completion

    func testCompletionMatchesTheNameAndItsWordsAndInsertsTheNick() {
        let members = [Member(nick: "amiantos"), Member(nick: "brad_"), Member(nick: "carol")]
        let names = ["amiantos": "Brad Root"]
        func rows(_ query: String, names: [String: String]? = names) -> [NickCompletion.Candidate] {
            NickCompletion.rows(
                speakers: SpeakerMap(), members: members, selfNick: "me", query: query, isChannel: true,
                displayName: names.map { table in { table[$0] } }
            )
        }
        XCTAssertEqual(rows("bra"), [
            NickCompletion.Candidate(nick: "amiantos", displayName: "Brad Root"),
            NickCompletion.Candidate(nick: "brad_"),
        ])
        XCTAssertEqual(rows("root").map(\.nick), ["amiantos"])
        XCTAssertEqual(rows("ami").map(\.nick), ["amiantos"])
        XCTAssertEqual(rows("car"), [NickCompletion.Candidate(nick: "carol")])
        // Without a name source it is the old matcher.
        XCTAssertEqual(rows("bra", names: nil).map(\.nick), ["brad_"])
        XCTAssertEqual(
            NickCompletion.candidates(speakers: SpeakerMap(), members: members, selfNick: "me", query: "bra", isChannel: true),
            ["brad_"]
        )
    }
}
