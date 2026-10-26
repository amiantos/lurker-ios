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
}
