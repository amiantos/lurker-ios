// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// Which style a buffer draws in, and what "apply to all" means.
///
/// Worth pinning because the semantics are the whole feature: the picker is two controls and an
/// alert, and everything a user could be surprised by lives in these rules.
final class MessageListStyleTests: XCTestCase {

    /// Pinned, because it decides what every existing install sees: a buffer nobody has explicitly
    /// set follows the default, so moving it moves them.
    func testCompactIsTheDefault() {
        XCTAssertEqual(MessageListStylePreferences().defaultStyle, .compact)
        XCTAssertEqual(MessageListStylePreferences().style(for: "1:#lurker"), .compact)
    }

    func testBuffersWithNoChoiceFollowTheDefault() {
        let prefs = MessageListStylePreferences(defaultStyle: .compact)
        XCTAssertEqual(prefs.style(for: "1:#lurker"), .compact)
        XCTAssertEqual(prefs.style(for: "anything"), .compact)
    }

    func testSettingOneBufferLeavesTheOthersAlone() {
        var prefs = MessageListStylePreferences(defaultStyle: .bubbles)
        prefs.set(.compact, for: "1:#lurker")
        XCTAssertEqual(prefs.style(for: "1:#lurker"), .compact)
        XCTAssertEqual(prefs.style(for: "1:#other"), .bubbles)
        XCTAssertEqual(prefs.defaultStyle, .bubbles)
    }

    /// Choosing the style that happens to be the current default is still a choice — "this one
    /// stays bubbles" — and has to survive a later "apply Compact to all" being cancelled, or
    /// rather, has to be recorded so it *isn't* silently swept up by an unrelated change.
    func testChoosingTheCurrentDefaultStillRecordsAChoice() {
        var prefs = MessageListStylePreferences(defaultStyle: .bubbles)
        prefs.set(.bubbles, for: "1:#lurker")
        XCTAssertEqual(prefs.overrides["1:#lurker"], .bubbles)
    }

    /// The Finder rule: "apply to all" means all, so it clears the exceptions rather than leaving
    /// them to contradict the default that was just set.
    func testApplyToAllClearsEveryException() {
        var prefs = MessageListStylePreferences(defaultStyle: .bubbles)
        prefs.set(.compact, for: "1:#lurker")
        prefs.set(.bubbles, for: "1:#other")

        prefs.applyToAll(.compact)

        XCTAssertEqual(prefs.defaultStyle, .compact)
        XCTAssertTrue(prefs.overrides.isEmpty)
        XCTAssertEqual(prefs.style(for: "1:#lurker"), .compact)
        XCTAssertEqual(prefs.style(for: "1:#other"), .compact)
        XCTAssertEqual(prefs.style(for: "1:#never-seen"), .compact)
    }

    /// Round-trips, because these live in UserDefaults as JSON and a decode failure would silently
    /// reset every buffer to the default style — and then the next write would make that
    /// permanent.
    func testPreferencesSurviveEncoding() throws {
        var prefs = MessageListStylePreferences(defaultStyle: .compact)
        prefs.set(.bubbles, for: "1:#lurker")
        let decoded = try JSONDecoder().decode(
            MessageListStylePreferences.self, from: JSONEncoder().encode(prefs)
        )
        XCTAssertEqual(decoded, prefs)
    }

    /// The reveal gesture belongs to the style that needs it. Compact stamps every line, so the
    /// drag would reveal something already on screen.
    func testOnlyBubblesRevealTimestampsOnDrag() {
        XCTAssertTrue(MessageListStyle.bubbles.revealsTimestamps)
        XCTAssertFalse(MessageListStyle.compact.revealsTimestamps)
    }

    func testEveryStyleIsPickable() {
        // The picker is built from `allCases`, so a style added without a title would ship blank.
        XCTAssertEqual(MessageListStyle.allCases.count, 2)
        for style in MessageListStyle.allCases {
            XCTAssertFalse(style.title.isEmpty, "\(style) needs a title")
        }
    }
}
