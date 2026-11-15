// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The compact layout's three density settings (lurker#1186, Mobile lurker#1224).
final class CompactDensityTests: XCTestCase {
    private func density(_ values: [String: SettingValue] = [:]) -> CompactDensity {
        CompactDensity(settings: Settings(registry: [:], values: values))
    }

    func testNothingStoredIsTheRegistryDefaults() {
        XCTAssertEqual(density(), CompactDensity(groupGap: 10, lineHeightPercent: 155, indent: 1))
        XCTAssertEqual(density(), .standard)
    }

    func testStoredValuesWin() {
        let d = density([
            CompactDensity.groupGapKey: .int(0),
            CompactDensity.lineHeightKey: .int(120),
            CompactDensity.indentKey: .int(3),
        ])
        XCTAssertEqual(d.groupGap, 0)
        XCTAssertEqual(d.lineHeightPercent, 120)
        XCTAssertEqual(d.indent, 3)
    }

    func testOutOfRangeValuesClampToTheRegistrysRange() {
        let low = density([
            CompactDensity.groupGapKey: .int(-4),
            CompactDensity.lineHeightKey: .int(50),
            CompactDensity.indentKey: .int(-1),
        ])
        XCTAssertEqual(low, CompactDensity(groupGap: 0, lineHeightPercent: 100, indent: 0))
        let high = density([
            CompactDensity.groupGapKey: .int(99),
            CompactDensity.lineHeightKey: .int(400),
            CompactDensity.indentKey: .int(20),
        ])
        XCTAssertEqual(high, CompactDensity(groupGap: 48, lineHeightPercent: 250, indent: 8))
    }

    func testAValueOfTheWrongTypeFallsBackToTheDefault() {
        XCTAssertEqual(density([CompactDensity.groupGapKey: .string("10")]).groupGap, 10)
    }

    func testTheRegistryDefaultIsUsedBeforeAnyOverride() {
        let registry = [
            CompactDensity.lineHeightKey: SettingOption(
                key: CompactDensity.lineHeightKey, label: "", description: "", type: .int, default: .int(170))
        ]
        let d = CompactDensity(settings: Settings(registry: registry, values: [:]))
        XCTAssertEqual(d.lineHeightPercent, 170)
    }

    // MARK: - A server from before the keys were renamed (its schema v28)

    private func option(_ key: String, _ value: Int) -> SettingOption {
        SettingOption(key: key, label: "", description: "", type: .int, default: .int(value))
    }

    func testAnOlderServersValuesAreReadUnderTheKeysItStillUses() {
        let d = density([
            "look.message.compact.group_gap": .int(4),
            "look.message.compact.line_height": .int(120),
            "look.message.compact.indent": .int(3),
        ])
        XCTAssertEqual(d, CompactDensity(groupGap: 4, lineHeightPercent: 120, indent: 3))
    }

    func testAnOlderServersRegistryDefaultIsReadTheSameWay() {
        let registry = ["look.message.compact.line_height": option("look.message.compact.line_height", 170)]
        XCTAssertEqual(CompactDensity(settings: Settings(registry: registry, values: [:])).lineHeightPercent, 170)
    }

    func testTheCurrentKeyWinsOverTheFormerOne() {
        // A stored value under the new key, and the new registry's default, both come before
        // anything under the old name.
        XCTAssertEqual(density([CompactDensity.indentKey: .int(2), "look.message.compact.indent": .int(7)]).indent, 2)
        let registry = [CompactDensity.indentKey: option(CompactDensity.indentKey, 1)]
        let settings = Settings(registry: registry, values: ["look.message.compact.indent": .int(7)])
        XCTAssertEqual(CompactDensity(settings: settings).indent, 1)
    }

    func testEveryRenamedKeyIsOneTheKitReads() {
        XCTAssertEqual(
            Set(Settings.formerKeys.keys),
            [
                CompactDensity.groupGapKey, CompactDensity.lineHeightKey, CompactDensity.indentKey,
                TimestampFormat.compactTimeKey, TimestampFormat.compactDateKey,
            ]
        )
        for (now, former) in Settings.formerKeys {
            XCTAssertNotEqual(now, former)
            XCTAssertFalse(now.contains("compact"), now)
            XCTAssertTrue(former.contains("compact"), former)
        }
        let old = Settings(registry: [:], values: ["look.buffer.time_format_compact": .string("h:mm a")])
        XCTAssertEqual(old.string(TimestampFormat.compactTimeKey, default: "HH:mm"), "h:mm a")
        XCTAssertNil(Settings(registry: [:], values: [:]).effective(TimestampFormat.compactTimeKey))
    }
}
