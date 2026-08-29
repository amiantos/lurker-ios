// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// `namesAChannel` — the guard in front of every join.
final class ChannelNameTests: XCTestCase {

    func testASigilOnlyTargetIsNotAChannelName() {
        // ⚠⚠ The whole reason this isn't built on `fold`. `fold` drops exactly ONE leading
        // sigil, so every one of these folds to something non-empty, the guard passes, and
        // `ensurePrefix` hands them along untouched — a JOIN for a channel with no name.
        XCTAssertFalse(ChannelName.namesAChannel("#"))
        XCTAssertFalse(ChannelName.namesAChannel("##"))
        XCTAssertFalse(ChannelName.namesAChannel("#&"))
        XCTAssertFalse(ChannelName.namesAChannel("&&"))
        XCTAssertFalse(ChannelName.namesAChannel("+"))
        XCTAssertFalse(ChannelName.namesAChannel("!"))
        XCTAssertFalse(ChannelName.namesAChannel(""))
    }

    func testARealNameIsAChannelNameWhateverItsSigils() {
        XCTAssertTrue(ChannelName.namesAChannel("lurker"))
        XCTAssertTrue(ChannelName.namesAChannel("#lurker"))
        // `##anime` is a real convention, and has to survive a guard aimed at `##`.
        XCTAssertTrue(ChannelName.namesAChannel("##anime"))
        // All four sigils — this repo's most-repeated bug is treating `#` as the only one.
        XCTAssertTrue(ChannelName.namesAChannel("&local"))
        XCTAssertTrue(ChannelName.namesAChannel("+modeless"))
        XCTAssertTrue(ChannelName.namesAChannel("!ABCDEfoo"))
    }

    func testWhitespaceIsNotAChannelName() {
        // Trimmed inside, so two call sites can't drift to different trims — which is exactly
        // what the two that existed had done, under a comment claiming they agreed.
        XCTAssertFalse(ChannelName.namesAChannel("   "))
        XCTAssertFalse(ChannelName.namesAChannel(" # "))
        XCTAssertTrue(ChannelName.namesAChannel("  #lurker\n"))
    }

    func testEnsurePrefixLeavesEveryRealSigilAlone() {
        // What the join sheet's footer promises: a `#` is added only when there is no sigil.
        XCTAssertEqual(ChannelName.ensurePrefix("lurker"), "#lurker")
        XCTAssertEqual(ChannelName.ensurePrefix("#lurker"), "#lurker")
        XCTAssertEqual(ChannelName.ensurePrefix("&local"), "&local")
        XCTAssertEqual(ChannelName.ensurePrefix("+modeless"), "+modeless")
        XCTAssertEqual(ChannelName.ensurePrefix("!ABCDEfoo"), "!ABCDEfoo")
    }
}
