// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Testing

@testable import LurkerKit

/// The canvas rule a preview still is judged by before a pixel of it is decoded.
@Suite("Preview image budget")
struct PreviewImageBudgetTests {

    @Test("a photograph passes: a phone frame and a 6000×4000 camera file are under the bound")
    func photographsPass() {
        #expect(PreviewImageBudget.admits(pixelWidth: 4032, pixelHeight: 3024))  // 12 MP
        #expect(PreviewImageBudget.admits(pixelWidth: 6000, pixelHeight: 4000))  // 24 MP, at the bound
        #expect(PreviewImageBudget.admits(pixelWidth: 1, pixelHeight: 1))
        #expect(PreviewImageBudget.admits(pixelWidth: 1, pixelHeight: PreviewImageBudget.maxPixels))
    }

    @Test("a canvas past the bound is refused, however few bytes it took")
    func bombsAreRefused() {
        #expect(!PreviewImageBudget.admits(pixelWidth: 20_000, pixelHeight: 20_000))
        #expect(!PreviewImageBudget.admits(pixelWidth: 1, pixelHeight: PreviewImageBudget.maxPixels + 1))
        #expect(!PreviewImageBudget.admits(pixelWidth: 6000, pixelHeight: 4001))
    }

    @Test("an empty or negative canvas is refused rather than divided by")
    func degenerateCanvases() {
        #expect(!PreviewImageBudget.admits(pixelWidth: 0, pixelHeight: 100))
        #expect(!PreviewImageBudget.admits(pixelWidth: 100, pixelHeight: 0))
        #expect(!PreviewImageBudget.admits(pixelWidth: -1, pixelHeight: 100))
    }

    /// ⚠ A header can declare any two numbers. Their product overflowing `Int` must be a
    /// refusal, not a trap.
    @Test("dimensions whose product overflows are refused without trapping")
    func overflowIsARefusal() {
        #expect(!PreviewImageBudget.admits(pixelWidth: Int.max, pixelHeight: 2))
        #expect(!PreviewImageBudget.admits(pixelWidth: Int.max, pixelHeight: Int.max))
    }
}
