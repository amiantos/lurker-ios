// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Settings sync (#65): the bootstrap parse, the live change frame, and the layering that
/// makes a read correct.
///
/// The layering is the part worth pinning down. `/api/settings/bootstrap` returns *stored*
/// values only — a user who has never opened settings gets `{}` — so every read has to fall
/// through to the registry default. Get that wrong and each bool reads false on a fresh
/// account, silently turning features off.
@MainActor
final class SettingsTests: XCTestCase {

    private let bootstrapJSON = ##"""
    {
      "registry": [
        {"key":"chat.consolidate_joins","label":"Consolidate joins","category":"chat","group":"noise",
         "type":"bool","default":true,"description":"Merge runs of join/part."},
        {"key":"chat.consolidate_max_names","label":"Max names","category":"chat","group":"noise",
         "type":"int","default":5,"min":1,"max":20,"description":"Names before \"and N others\"."},
        {"key":"look.message.layout","label":"Layout","category":"look","group":"message",
         "type":"enum","default":"auto","choices":["auto","standard","compact"],"description":"Row layout."},
        {"key":"chat.quit_message","label":"Quit message","category":"chat","group":"composing",
         "type":"string","default":"","description":"Sent with QUIT."}
      ],
      "values": {"chat.consolidate_joins": false, "chat.consolidate_max_names": 9}
    }
    """##

    private func bootstrapped() -> ChatState {
        LurkerStore.reduce(ChatState(), FrameParser.parseSettingsBootstrap(bootstrapJSON))
    }

    // MARK: - Parsing

    func testBootstrapParsesRegistryAndValues() {
        guard case let .settingsBootstrap(registry, values) = FrameParser.parseSettingsBootstrap(bootstrapJSON) else {
            return XCTFail("expected settingsBootstrap")
        }
        XCTAssertEqual(registry.count, 4)
        XCTAssertEqual(registry["chat.consolidate_joins"]?.type, .bool)
        XCTAssertEqual(registry["chat.consolidate_joins"]?.default, .bool(true))
        XCTAssertEqual(registry["chat.consolidate_max_names"]?.min, 1)
        XCTAssertEqual(registry["chat.consolidate_max_names"]?.max, 20)
        XCTAssertEqual(registry["look.message.layout"]?.choices, ["auto", "standard", "compact"])
        // Only what the user actually stored.
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values["chat.consolidate_joins"], .bool(false))
    }

    /// `JSONSerialization` decodes both `true` and `1` into `NSNumber`, so a naive `as? Int`
    /// claims booleans and a naive `as? Bool` claims any nonzero int. Confusing them would
    /// turn every bool setting into `int(1)` and every write back into a type error.
    func testBoolsAndIntsDoNotBleedIntoEachOther() {
        XCTAssertEqual(SettingValue.from(true), .bool(true))
        XCTAssertEqual(SettingValue.from(false), .bool(false))
        XCTAssertEqual(SettingValue.from(1), .int(1))
        XCTAssertEqual(SettingValue.from(0), .int(0))
    }

    func testSettingValueDecodesEveryWireShape() {
        XCTAssertEqual(SettingValue.from("hello"), .string("hello"))
        XCTAssertEqual(SettingValue.from(["a", "b"]), .stringList(["a", "b"]))
        XCTAssertNil(SettingValue.from(NSNull()))
    }

    /// A registry entry we can't represent is skipped rather than half-built: an option with
    /// no usable default would make `effective` return nil for an unset key, and every caller
    /// would silently fall through to its own fallback — the drift this layer prevents.
    func testUnusableRegistryEntriesAreSkipped() {
        let json = ##"""
        {"registry":[
          {"key":"ok","label":"L","type":"bool","default":true,"description":"","category":"c","group":"g"},
          {"key":"no-type","label":"L","default":true,"description":"","category":"c","group":"g"},
          {"key":"no-default","label":"L","type":"bool","description":"","category":"c","group":"g"},
          {"key":"","label":"L","type":"bool","default":true,"description":"","category":"c","group":"g"}
        ],"values":{}}
        """##
        guard case let .settingsBootstrap(registry, _) = FrameParser.parseSettingsBootstrap(json) else {
            return XCTFail("expected settingsBootstrap")
        }
        XCTAssertEqual(Array(registry.keys), ["ok"])
    }

    func testSettingsChangeFrameParses() {
        let frame = FrameParser.parseWs(##"{"kind":"settings","changes":{"chat.smart_filter":true}}"##)
        XCTAssertEqual(frame, .settingsChanged(["chat.smart_filter": .bool(true)]))
    }

    /// The server sends `changes || {}`, so an empty patch is legal and must be a no-op rather
    /// than anything that could be mistaken for "everything was cleared".
    func testEmptyChangeFrameIsANoOp() {
        var state = bootstrapped()
        state = LurkerStore.reduce(state, FrameParser.parseWs(##"{"kind":"settings","changes":{}}"##))
        XCTAssertEqual(state.settings.bool("chat.consolidate_joins", default: true), false)
        XCTAssertEqual(state.settings.int("chat.consolidate_max_names", default: 5), 9)
    }

    // MARK: - Layering: stored → registry default → caller fallback

    func testStoredValueWins() {
        let state = bootstrapped()
        XCTAssertEqual(state.settings.bool("chat.consolidate_joins", default: true), false)
        XCTAssertEqual(state.settings.int("chat.consolidate_max_names", default: 5), 9)
    }

    /// The trap. `values` holds nothing for this key, so a read that didn't fall through to
    /// the registry would report `false` for a setting the server considers `true`.
    func testUnsetKeyFallsThroughToTheRegistryDefault() {
        let state = bootstrapped()
        XCTAssertEqual(state.settings.effective("look.message.layout"), .string("auto"))
        XCTAssertEqual(state.settings.string("look.message.layout", default: "zzz"), "auto")
    }

    /// Before bootstrap lands there is no registry either, so the caller's fallback is the
    /// only answer — and it must be the registry's own default, or behavior shifts under the
    /// user a moment after launch.
    func testCallerFallbackAppliesBeforeBootstrap() {
        let fresh = ChatState()
        XCTAssertFalse(fresh.settings.loaded)
        XCTAssertEqual(fresh.settings.bool("chat.consolidate_joins", default: true), true)
        XCTAssertEqual(fresh.settings.int("chat.consolidate_max_names", default: 5), 5)
    }

    /// A self-hosted server can legitimately be older than the app, so a key it has never
    /// heard of has to degrade to the caller's fallback rather than to a nil-shaped hole.
    func testUnknownKeyFallsBackToTheCaller() {
        let state = bootstrapped()
        XCTAssertNil(state.settings.effective("chat.setting_from_the_future"))
        XCTAssertTrue(state.settings.bool("chat.setting_from_the_future", default: true))
    }

    /// A read of the wrong type must not coerce — it degrades to the fallback, so a server
    /// that changes a setting's type can't make the app render nonsense.
    func testTypeMismatchFallsBackRatherThanCoercing() {
        let state = bootstrapped()
        XCTAssertEqual(state.settings.int("chat.consolidate_joins", default: 7), 7)
        XCTAssertEqual(state.settings.string("chat.consolidate_max_names", default: "x"), "x")
    }

    // MARK: - Live updates

    func testChangeFramePatchesOneKeyAndLeavesTheRest() {
        var state = bootstrapped()
        state = LurkerStore.reduce(state, .settingsChanged(["chat.consolidate_joins": .bool(true)]))
        XCTAssertTrue(state.settings.bool("chat.consolidate_joins", default: false))
        // The other stored value survives — a patch, not a replace.
        XCTAssertEqual(state.settings.int("chat.consolidate_max_names", default: 5), 9)
    }

    func testChangeFrameCanSetAPreviouslyUnsetKey() {
        var state = bootstrapped()
        state = LurkerStore.reduce(state, .settingsChanged(["look.message.layout": .string("compact")]))
        XCTAssertEqual(state.settings.string("look.message.layout", default: "auto"), "compact")
    }

    func testBootstrapReplacesRatherThanMerges() {
        var state = bootstrapped()
        state = LurkerStore.reduce(state, .settingsChanged(["look.message.layout": .string("compact")]))
        // A reconnect re-bootstraps: the server's stored set is authoritative, so a value that
        // is no longer stored must revert to its default rather than linger from the old map.
        state = LurkerStore.reduce(state, FrameParser.parseSettingsBootstrap(bootstrapJSON))
        XCTAssertEqual(state.settings.string("look.message.layout", default: "auto"), "auto")
    }

    // MARK: - REST `{values}` replaces rather than merges

    /// The server drops a row when a key is set back to its default — "no override"
    /// (`settingsService.ts:72`) — so a `PATCH` returning to the default comes back as an
    /// ABSENCE. Merged, the cleared override would survive locally *and* get persisted to the
    /// cache, leaving a setting stuck at a value the user just cleared.
    func testRestValuesRemoveAKeyThatIsNoLongerStored() {
        var state = bootstrapped()
        XCTAssertEqual(state.settings.bool("chat.consolidate_joins", default: true), false)
        // The user switches it back on: `true` == the registry default, so the server deletes
        // the row and its reply omits the key entirely.
        state = LurkerStore.reduce(state, .settingsValues(["chat.consolidate_max_names": .int(9)]))
        XCTAssertTrue(
            state.settings.bool("chat.consolidate_joins", default: true),
            "a key absent from the full stored set must revert to its default"
        )
        XCTAssertNil(state.settings.values["chat.consolidate_joins"])
        // …and the untouched one is still there.
        XCTAssertEqual(state.settings.int("chat.consolidate_max_names", default: 5), 9)
    }

    /// The WS echo of the same write is a patch and arrives separately; applying it after the
    /// replace must not resurrect anything.
    func testEchoAfterReplaceIsIdempotent() {
        var state = bootstrapped()
        state = LurkerStore.reduce(state, .settingsValues(["chat.consolidate_max_names": .int(9)]))
        state = LurkerStore.reduce(state, .settingsChanged(["chat.consolidate_joins": .bool(true)]))
        XCTAssertTrue(state.settings.bool("chat.consolidate_joins", default: false))
    }

    func testReplaceLeavesTheRegistryAlone() {
        var state = bootstrapped()
        state = LurkerStore.reduce(state, .settingsValues([:]))
        XCTAssertEqual(state.settings.registry.count, 4)
        // Everything falls back to its default, which is exactly "nothing overridden".
        XCTAssertEqual(state.settings.int("chat.consolidate_max_names", default: 0), 5)
    }

    /// A mixed array can't be represented exactly, and `compactMap`-ing the strings out of it
    /// would mean writing back a different list than the server sent.
    func testMixedArrayDoesNotDecodeToAPartialList() {
        XCTAssertNil(SettingValue.from(["a", 1, "b"] as [Any]))
        XCTAssertEqual(SettingValue.from(["a", "b"]), .stringList(["a", "b"]))
    }

    func testUnrepresentableValuesAreSkippedNotGuessed() {
        let values = FrameParser.parseSettingValues([
            "good": "yes",
            "bad": ["a", 1] as [Any],
        ])
        XCTAssertEqual(values, ["good": .string("yes")])
    }

    // MARK: - The values cache

    /// Its own suite, so tests never scribble on the app's defaults.
    private func isolatedCache() -> SettingsCache {
        let suite = UserDefaults(suiteName: "lurker.tests.\(UUID().uuidString)")!
        return SettingsCache(defaults: suite)
    }

    func testCacheRoundTripsEveryValueKind() {
        let cache = isolatedCache()
        let values: [String: SettingValue] = [
            "a.bool": .bool(false),
            "a.int": .int(9),
            "a.string": .string("compact"),
            "a.list": .stringList(["x", "y"]),
        ]
        cache.save(values)
        XCTAssertEqual(cache.load(), values)
    }

    func testCacheStartsEmptyAndClears() {
        let cache = isolatedCache()
        XCTAssertEqual(cache.load(), [:])
        cache.save(["a.bool": .bool(true)])
        cache.clear()
        XCTAssertEqual(cache.load(), [:])
    }

    /// A save replaces rather than merges: it mirrors the server's stored set, and a setting
    /// reset to its default disappears from that set. Merging would keep the old value alive
    /// locally forever.
    func testCacheSaveReplacesRatherThanMerges() {
        let cache = isolatedCache()
        cache.save(["a": .bool(true), "b": .int(1)])
        cache.save(["a": .bool(true)])
        XCTAssertEqual(cache.load(), ["a": .bool(true)])
    }

    /// The reason the cache exists. With no registry at all — bootstrap failed, or hasn't
    /// landed — a cached `false` must still be what a privacy gate reads, because the fallback
    /// on `chat.send_typing_notifications` is `true` and the user turned it off.
    func testCachedValueOverridesTheFallbackWithNoRegistry() {
        var state = ChatState()
        state = LurkerStore.reduce(state, .settingsChanged(["chat.send_typing_notifications": .bool(false)]))
        XCTAssertFalse(state.settings.loaded, "values alone must not claim a real bootstrap")
        XCTAssertFalse(
            state.settings.bool("chat.send_typing_notifications", default: true),
            "a cached off must beat the default-on fallback"
        )
    }

    /// Seeding from cache supplies values but no registry, so the settings *screen* can still
    /// tell "we have nothing to render controls from" apart from "this server has no settings".
    func testSeedingFromCacheLeavesLoadedFalse() {
        let state = LurkerStore.reduce(ChatState(), .settingsChanged(["a": .bool(true)]))
        XCTAssertFalse(state.settings.loaded)
        XCTAssertTrue(state.settings.registry.isEmpty)
    }

    // MARK: - Write encoding

    func testValuesRoundTripToJSON() {
        XCTAssertEqual(SettingValue.bool(true).jsonValue as? Bool, true)
        XCTAssertEqual(SettingValue.int(9).jsonValue as? Int, 9)
        XCTAssertEqual(SettingValue.string("compact").jsonValue as? String, "compact")
        XCTAssertEqual(SettingValue.stringList(["a"]).jsonValue as? [String], ["a"])
        // The whole point: what we send has to survive JSONSerialization unchanged.
        let body = ["changes": [
            "chat.consolidate_joins": SettingValue.bool(false).jsonValue,
            "chat.consolidate_max_names": SettingValue.int(3).jsonValue,
        ]]
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    }
}
