// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Sweep L08: the phone writes its time zone to `system.timezone` when the server's differs, as the
/// web does, so push quiet hours and the auto-away stamp follow the phone rather than the last browser.
@MainActor
final class TimeZoneSyncTests: XCTestCase {
    private let suite = "chat.lurker.tests.timezonesync"

    private func makeModel() -> (ChatViewModel, () -> [String]) {
        let model = ChatViewModel(
            sessions: SessionStore(service: suite),
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: suite)!)
        )
        var written: [String] = []
        model.timeZoneWriteSeam = { written.append($0) }
        return (model, { written })
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var here: String { TimeZone.current.identifier }

    /// A zone no test machine is in, so it always differs from `here`.
    private var elsewhere: String { here == "Pacific/Chatham" ? "Pacific/Kiritimati" : "Pacific/Chatham" }

    func testABootstrapWithAnotherZoneWritesThePhones() {
        let (model, written) = makeModel()
        model.handle(.settingsBootstrap(registry: [:], values: ["system.timezone": .string(elsewhere)]))
        XCTAssertEqual(written(), [here])
    }

    func testABootstrapWithNoZoneWritesThePhones() {
        let (model, written) = makeModel()
        model.handle(.settingsBootstrap(registry: [:], values: [:]))
        XCTAssertEqual(written(), [here])
    }

    func testABootstrapAlreadyInThisZoneWritesNothing() {
        let (model, written) = makeModel()
        model.handle(.settingsBootstrap(registry: [:], values: ["system.timezone": .string(here)]))
        XCTAssertEqual(written(), [])
    }

    /// Another device's write is never answered, so two devices in different zones can't trade it.
    func testAnotherDevicesZoneIsNotAnswered() {
        let (model, written) = makeModel()
        model.handle(.settingsBootstrap(registry: [:], values: ["system.timezone": .string(here)]))
        model.handle(.settingsChanged(["system.timezone": .string(elsewhere)], uploadLimits: .unstated))
        XCTAssertEqual(written(), [])
    }

    func testAnEmptyZoneIsNeverWritten() {
        let (model, written) = makeModel()
        model.syncTimeZone("")
        XCTAssertEqual(written(), [])
    }
}
