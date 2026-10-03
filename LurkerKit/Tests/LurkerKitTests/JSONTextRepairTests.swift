// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing

@testable import LurkerKit

/// What `JSON.parse` reads, Foundation must read too (lurker-ios#195, #196). Driven through
/// `FrameParser.jsonObject`, the path every frame and REST body takes, so a parser that stops
/// repairing fails here rather than in a test of the repair on its own.
@Suite("JSON text repair")
struct JSONTextRepairTests {

    private func scalars(_ json: String, _ key: String = "a") -> [UInt32]? {
        (FrameParser.jsonObject(from: json)?[key] as? String)?.unicodeScalars.map(\.value)
    }

    // MARK: - Lone surrogates (#195)

    @Test("a lone high surrogate escape costs one character, not the document")
    func loneHighSurrogate() {
        #expect(scalars(#"{"a":"fun \ud83d","b":1}"#) == [0x66, 0x75, 0x6E, 0x20, 0xFFFD])
    }

    @Test("a lone low surrogate escape, at the start or after text")
    func loneLowSurrogate() {
        #expect(scalars(#"{"a":"\ude00x"}"#) == [0xFFFD, 0x78])
        #expect(scalars(#"{"a":"x\uDE00"}"#) == [0x78, 0xFFFD])
    }

    @Test("a high half followed by another high half: the first is lone, the pair after it is kept")
    func highThenPair() {
        #expect(scalars(#"{"a":"\ud83d😀"}"#) == [0xFFFD, 0x1F600])
    }

    @Test("a high half followed by a non-surrogate escape is lone")
    func highThenOrdinaryEscape() {
        #expect(scalars(#"{"a":"\ud83dA"}"#) == [0xFFFD, 0x41])
    }

    @Test("a well-formed pair, in either case, is untouched")
    func pairIsKept() {
        #expect(scalars(#"{"a":"😀"}"#) == [0x1F600])
        #expect(scalars(#"{"a":"😀"}"#) == [0x1F600])
    }

    @Test("an escaped backslash before 'ud83d' is text, not an escape")
    func escapedBackslashIsNotAnEscape() {
        #expect(scalars(#"{"a":"\\ud83d"}"#) == Array(#"\ud83d"#.unicodeScalars.map(\.value)))
    }

    @Test("an escaped quote doesn't end the string, so a surrogate after it is still repaired")
    func escapedQuoteKeepsTheStringOpen() {
        #expect(scalars(#"{"a":"say \"\ud83d\" ok"}"#) == Array("say \"\u{FFFD}\" ok".unicodeScalars.map(\.value)))
    }

    @Test("a lone surrogate in a key is repaired too")
    func loneSurrogateInAKey() {
        #expect(FrameParser.jsonObject(from: #"{"\ud83d":1}"#)?["\u{FFFD}"] as? Int == 1)
    }

    @Test("a document malformed some other way is still refused")
    func otherDamageIsStillRefused() {
        #expect(FrameParser.jsonObject(from: #"{"a":"\u12"}"#) == nil)
        #expect(FrameParser.jsonObject(from: #"{"a":"x"#) == nil)
    }

    // MARK: - Leading U+FEFF (#196)

    @Test("a leading U+FEFF survives, raw or escaped")
    func leadingBOMSurvives() {
        #expect(scalars("{\"a\":\"\u{FEFF}hi\"}") == [0xFEFF, 0x68, 0x69])
        #expect(scalars(#"{"a":"\ufeffhi"}"#) == [0xFEFF, 0x68, 0x69])
        #expect(scalars(#"{"a":"\uFEFFhi"}"#) == [0xFEFF, 0x68, 0x69])
    }

    @Test("a string that is only U+FEFF, or starts with two, keeps every one")
    func everyBOMIsKept() {
        #expect(scalars(#"{"a":"\ufeff"}"#) == [0xFEFF])
        #expect(scalars("{\"a\":\"\u{FEFF}\u{FEFF}x\"}") == [0xFEFF, 0xFEFF, 0x78])
    }

    @Test("a key that starts with U+FEFF is a different key from one that doesn't")
    func leadingBOMInAKey() {
        let object = FrameParser.jsonObject(from: "{\"\u{FEFF}k\":1,\"k\":2}")
        #expect(object?["\u{FEFF}k"] as? Int == 1)
        #expect(object?["k"] as? Int == 2)
    }

    @Test("a U+FEFF that isn't first was never touched, and still isn't")
    func innerBOMIsUntouched() {
        #expect(scalars("{\"a\":\"h\u{FEFF}i\"}") == [0x68, 0xFEFF, 0x69])
    }

    @Test("inside arrays and nested objects")
    func nested() {
        let object = FrameParser.jsonObject(from: #"{"a":{"b":["\ufeffx","\ud83d"]}}"#)
        let strings = (object?["a"] as? [String: Any])?["b"] as? [String]
        #expect(strings?.map { $0.unicodeScalars.map(\.value) } == [[0xFEFF, 0x78], [0xFFFD]])
    }

    @Test("the BOM is doubled only for a decoder that strips one")
    func doublingFollowsTheDecoder() {
        // Asked of Foundation, not assumed: a Foundation that stopped stripping would otherwise
        // show two in every such string. Pinned both ways through the pure pass.
        var text = #"["\ufeffx"]"#
        let doubled = text.withUTF8 { JSONTextRepair.repaired($0, doubleLeadingBOM: true) }
        let left = text.withUTF8 { JSONTextRepair.repaired($0, doubleLeadingBOM: false) }
        #expect(doubled.map { Array($0) } == Array("[\"\u{FEFF}\\ufeffx\"]".utf8))
        #expect(left == nil)
    }

    @Test("a document with nothing to repair is not rewritten")
    func cleanDocumentIsNotCopied() {
        var text = #"{"a":"plain \"quoted\" text é 😀","b":[1,2]}"#
        #expect(text.withUTF8 { JSONTextRepair.repaired($0, doubleLeadingBOM: true) } == nil)
    }
}
