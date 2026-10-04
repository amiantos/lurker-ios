// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Locks nick completion to the web client's `nickCompletion.ts`: speakers before
/// members, recency order, self excluded, departed speakers dropped in channels — plus
/// the token scanner and the addressing suffix the composer inserts.
final class NickCompletionTests: XCTestCase {

    /// A speaker map where each nick spoke at its index — so the LAST listed spoke most recently,
    /// the way a buffer's history reads.
    private func spoke(_ nicks: String...) -> SpeakerMap {
        var map = SpeakerMap()
        for (index, nick) in nicks.enumerated() {
            map.record(nick: nick, at: Date(timeIntervalSince1970: TimeInterval(index + 1)))
        }
        return map
    }

    // MARK: - Candidates

    func testRecentSpeakersLeadNewestFirstThenMembersAlphabetically() {
        let candidates = NickCompletion.candidates(
            speakers: spoke("alice", "bob"),
            members: [Member(nick: "zoe"), Member(nick: "alice"), Member(nick: "bob"), Member(nick: "carol")],
            selfNick: "me",
            query: "",
            isChannel: true
        )
        XCTAssertEqual(candidates, ["bob", "alice", "carol", "zoe"],
                       "bob spoke last → first; then alice; members fill the rest A→Z")
    }

    func testFilteringIsCaseInsensitiveAndKeepsRecencyOrder() {
        let candidates = NickCompletion.candidates(
            speakers: spoke("Anna", "arthur"),
            members: [Member(nick: "Anna"), Member(nick: "arthur"), Member(nick: "AXEL"), Member(nick: "bob")],
            selfNick: nil,
            query: "a",
            isChannel: true
        )
        XCTAssertEqual(candidates, ["arthur", "Anna", "AXEL"])
    }

    func testYouAreNeverACandidate() {
        let candidates = NickCompletion.candidates(
            speakers: spoke("ME", "alice"),
            members: [Member(nick: "me"), Member(nick: "alice")],
            selfNick: "me",
            query: "",
            isChannel: true
        )
        XCTAssertEqual(candidates, ["alice"], "self is excluded as speaker and as member, case-folded")
    }

    /// The web filters channel speakers by current membership: completing someone who
    /// left addresses nobody. A DM has no member list, so its speakers pass unfiltered.
    func testADepartedSpeakerIsDroppedInChannelsButNotDMs() {
        let speakers = spoke("ghost", "alice")
        let inChannel = NickCompletion.candidates(
            speakers: speakers, members: [Member(nick: "alice")],
            selfNick: nil, query: "", isChannel: true
        )
        XCTAssertEqual(inChannel, ["alice"])

        let inDM = NickCompletion.candidates(
            speakers: speakers, members: [],
            selfNick: nil, query: "", isChannel: false
        )
        XCTAssertEqual(inDM, ["alice", "ghost"])
    }

    func testTheCapHolds() {
        let members = ["alice", "bob", "carol", "dave", "erin", "frank"].map { Member(nick: $0) }
        let candidates = NickCompletion.candidates(
            speakers: spoke("alice", "bob"), members: members, selfNick: nil, query: "", isChannel: true
        )
        XCTAssertEqual(candidates, ["bob", "alice", "carol", "dave"], "capped at four")
    }

    /// A speaker is offered as they last spelled their nick, not as the map's lowercased key.
    func testASpeakerKeepsTheirSpelling() {
        XCTAssertEqual(
            NickCompletion.candidates(
                speakers: spoke("Alice"), members: [], selfNick: nil, query: "al", isChannel: false
            ),
            ["Alice"]
        )
    }

    // MARK: - Token scanning

    func testAnAtTokenUnderTheCaretIsActive() {
        let token = NickCompletion.activeMention(in: "hey @al", caret: 7)
        XCTAssertEqual(token, NickCompletion.MentionToken(start: 4, end: 7, query: "al"))
    }

    func testABareAtOpensAnEmptyQuery() {
        XCTAssertEqual(NickCompletion.activeMention(in: "@", caret: 1)?.query, "")
    }

    /// Caret mid-word: the query answers what's typed so far, but the token spans the
    /// whole word — completion replaces all of it, so `@al|ice` can't become "aliceice".
    func testACaretMidWordFiltersToTheCaretButSpansTheWord() {
        let token = NickCompletion.activeMention(in: "@alice more", caret: 3)
        XCTAssertEqual(token, NickCompletion.MentionToken(start: 0, end: 6, query: "al"))
    }

    func testAnEmailShapedWordIsNotAMention() {
        XCTAssertNil(NickCompletion.activeMention(in: "mail user@host", caret: 14),
                     "the @ must open the word — matching the web's startsWith('@')")
    }

    func testACaretOutsideTheTokenDeactivatesIt() {
        XCTAssertNil(NickCompletion.activeMention(in: "@al done ", caret: 9),
                     "past the token's word there is no active mention")
        XCTAssertNil(NickCompletion.activeMention(in: "plain text", caret: 0))
    }

    // MARK: - Bare words (lurker-android#57)

    /// The web's mobile strip: two letters of a nick ask without an `@`, and completion
    /// replaces the word from its first letter.
    func testABareWordOfTwoLettersAsks() {
        XCTAssertEqual(NickCompletion.activeMention(in: "hey al", caret: 6),
                       NickCompletion.MentionToken(start: 4, end: 6, query: "al"))
        XCTAssertEqual(NickCompletion.activeMention(in: "al", caret: 2),
                       NickCompletion.MentionToken(start: 0, end: 2, query: "al"))
        XCTAssertEqual(NickCompletion.activeMention(in: "al more", caret: 2)?.query, "al",
                       "the end of a word, not of the text")
    }

    func testABareWordOfOneCharacterDoesNot() {
        XCTAssertNil(NickCompletion.activeMention(in: "hey a", caret: 5),
                     "every \"I\" and \"a\" would float the pills")
        XCTAssertNil(NickCompletion.activeMention(in: "hey \u{1F44D}", caret: 6),
                     "one emoji is one character, not its two UTF-16 units")
    }

    /// A caret placed inside a word is editing it: pills there would float over every typo
    /// fix, and a pick would replace the rest of the word ("al|ready" → "alice ").
    func testABareCaretInsideAWordDoesNotAsk() {
        XCTAssertNil(NickCompletion.activeMention(in: "I already said", caret: 4))
        XCTAssertNil(NickCompletion.activeMention(in: "thanks alice's idea", caret: 9))
    }

    /// Completion replaces the whole word, so a word holding an `@` past its start never
    /// asks, in either shape: it would take the `@host` with it.
    func testAWordWithAnAtPastItsStartDoesNotAsk() {
        XCTAssertNil(NickCompletion.activeMention(in: "mail user@host", caret: 14))
        XCTAssertNil(NickCompletion.activeMention(in: "@alice@host.com", caret: 3),
                     "even after the caret, an @… would lose its tail")
        XCTAssertNil(NickCompletion.activeMention(in: "@a@b", caret: 4))
    }

    func testACommandOrChannelWordDoesNotAsk() {
        XCTAssertNil(NickCompletion.activeMention(in: "/jo", caret: 3))
        XCTAssertNil(NickCompletion.activeMention(in: "//jo", caret: 4), "an escaped command")
        for sigil in ["#", "&", "+", "!"] {
            XCTAssertNil(NickCompletion.activeMention(in: "see \(sigil)li", caret: 7), sigil)
        }
    }

    /// A command's arguments are keys, passwords and new nicks: a bare word stays out of them.
    /// `/me`'s argument is speech, `//` escapes a command, and an `@` asks anywhere.
    func testACommandLineAsksOnlyForMeOrAnAt() {
        XCTAssertNil(NickCompletion.activeMention(in: "/msg NickServ IDENTIFY hu", caret: 25))
        XCTAssertNil(NickCompletion.activeMention(in: "  /nick al", caret: 10),
                     "the composer trims, so leading whitespace is still a command")
        XCTAssertEqual(NickCompletion.activeMention(in: "/me waves at al", caret: 15)?.query, "al")
        XCTAssertEqual(NickCompletion.activeMention(in: "/ME waves at al", caret: 15)?.query, "al")
        XCTAssertEqual(NickCompletion.activeMention(in: "/shrug ask al", caret: 13)?.query, "al",
                       "/shrug's argument is speech too")
        XCTAssertNil(NickCompletion.activeMention(in: "/meow al", caret: 8), "a verb, not a prefix")
        XCTAssertEqual(NickCompletion.activeMention(in: "//x al", caret: 6)?.query, "al")
        XCTAssertEqual(NickCompletion.activeMention(in: "/topic hi @al", caret: 13)?.query, "al")
    }

    func testAnAtStillAsksFromItsFirstKeystrokeAnywhereInTheWord() {
        XCTAssertEqual(NickCompletion.activeMention(in: "hey @a", caret: 6)?.query, "a",
                       "the bare threshold never applies to an @")
        XCTAssertEqual(NickCompletion.activeMention(in: "@alice", caret: 3)?.query, "al")
    }

    // MARK: - Addressing suffix

    private func suffix(_ start: Int, _ text: String, _ punctuation: String = ":") -> String {
        NickCompletion.addressingSuffix(beforeTokenAt: start, in: text, punctuation: punctuation)
    }

    func testLineStartAddressesWithColonMidSentenceWithSpace() {
        XCTAssertEqual(suffix(0, "@al"), ": ")
        // Any leading whitespace still counts as line start (web: /(^|\n)\s*$/)…
        XCTAssertEqual(suffix(2, "  @al"), ": ")
        XCTAssertEqual(suffix(1, "\t@al"), ": ")
        // …and so does the start of a wrapped line.
        XCTAssertEqual(suffix(6, "hello\n@al"), ": ")
        XCTAssertEqual(suffix(4, "cc: @al"), " ")
    }

    // MARK: - The suffix is a setting (#133, web #835)
    //
    // Ported from the web's `MessageInput.completion.test.ts` (the #835 block under
    // `describe('nicks')`). The web exercises the four paths that seed a line-start
    // session — picker, in-place Tab, strip, Reply; iOS has two (the @ picker and
    // Reply), and both read through the same pair of helpers tested here.

    private func settings(_ value: String?) -> Settings {
        Settings(
            registry: [
                "input.completion.nick_suffix": SettingOption(
                    key: "input.completion.nick_suffix", label: "Nick completion suffix",
                    description: "", type: .string, default: .string(":"))
            ],
            values: value.map { ["input.completion.nick_suffix": .string($0)] } ?? [:]
        )
    }

    func testAddressingPunctuationComesFromTheSetting() {
        XCTAssertEqual(NickCompletion.addressPunctuation(settings(",")), ",")
        XCTAssertEqual(suffix(0, "@al", NickCompletion.addressPunctuation(settings(","))), ", ")
        // Mid-line is a bare space whatever the setting says — the setting only touches
        // the line-start form.
        XCTAssertEqual(suffix(4, "cc: @al", ","), " ")
    }

    func testAnEmptyPunctuationStillAddressesWithASpace() {
        // The path most likely to be handed "" and drop the space with it.
        XCTAssertEqual(NickCompletion.addressPunctuation(settings("")), "")
        XCTAssertEqual(suffix(0, "@al", ""), " ")
    }

    func testAnUnsetOrUnknownKeyFallsBackToTheRegistryDefault() {
        XCTAssertEqual(NickCompletion.addressPunctuation(settings(nil)), ":",
                       "no stored value — the registry default")
        XCTAssertEqual(NickCompletion.addressPunctuation(Settings()), ":",
                       "a server too old to know the key, or the window before bootstrap")
    }

    func testTheStoredValueNormalisesTheSameWayForAControlAsForTheCompletion() {
        // The settings pull-down matches the stored value against the forms it offers with
        // this overload, so a `", "` written from the web checks the `","` row rather than
        // showing up as a custom value beside an identical-looking one.
        XCTAssertEqual(NickCompletion.addressPunctuation(", "), ",")
        XCTAssertEqual(NickCompletion.addressPunctuation(" "), "")
        XCTAssertEqual(NickCompletion.addressPunctuation("->"), "->")
    }

    func testTrailingWhitespaceInTheSettingIsDroppedNotDoubled() {
        // The description shows the form as `nick: `, so typing exactly that in is the
        // natural mistake; and a quoted " " is the natural way to ask for "space only".
        XCTAssertEqual(NickCompletion.addressPunctuation(settings(", ")), ",")
        XCTAssertEqual(suffix(0, "@al", NickCompletion.addressPunctuation(settings(", "))), ", ")
        XCTAssertEqual(NickCompletion.addressPunctuation(settings(" ")), "")
        XCTAssertEqual(suffix(0, "@al", NickCompletion.addressPunctuation(settings(" "))), " ")
    }

    func testThePunctuationIsNamedForVoiceOver() {
        // The settings pull-down's labels are samples of the form — `nick:`, `nick,` — which
        // differ only by a trailing mark, and VoiceOver reads none of them at its default
        // verbosity. Names are what it reads instead.
        XCTAssertEqual(NickCompletion.spokenPunctuation(":"), "Colon")
        XCTAssertEqual(NickCompletion.spokenPunctuation(","), "Comma")
        XCTAssertEqual(NickCompletion.spokenPunctuation(";"), "Semicolon")
        XCTAssertEqual(NickCompletion.spokenPunctuation(""), "Space only")
    }

    func testAFreeFormPunctuationIsNamedByTheSameRule() {
        // The value is free-form on the web, and a mark the phone doesn't offer is exactly the
        // one a VoiceOver user can't discover any other way — naming only the four would leave
        // this one mute, or announced as "custom", which says nothing about what is in force.
        XCTAssertEqual(NickCompletion.spokenPunctuation(";p"), "Semicolon p")
        XCTAssertEqual(NickCompletion.spokenPunctuation("->"), "Hyphen-minus greater-than sign")
        XCTAssertEqual(NickCompletion.spokenPunctuation("!"), "Exclamation mark")
        // A letter or a digit already reads aloud; "latin small letter p" is not an
        // improvement. Nor is sentence case, which would announce a capital P — a different
        // suffix from the one that is set.
        XCTAssertEqual(NickCompletion.spokenPunctuation("p"), "p")
        XCTAssertEqual(NickCompletion.spokenPunctuation("2"), "2")
        XCTAssertEqual(NickCompletion.spokenPunctuation("p;"), "p semicolon")
    }

    // MARK: - Reply's already-addressed test

    func testReplyRecognisesADraftAddressedUnderTheConfiguredForm() {
        XCTAssertTrue(NickCompletion.isAddressed("bob, sure", to: "bob", punctuation: ","),
                      "a second Reply must not stack a second `bob, `")
    }

    func testReplyRecognisesADraftAddressedUnderAnotherForm() {
        // The draft can predate a settings change, or come from a client with its own form
        // — drafts sync — so this must not become `bob, bob: sure`.
        XCTAssertTrue(NickCompletion.isAddressed("bob: sure", to: "bob", punctuation: ","))
        XCTAssertTrue(NickCompletion.isAddressed("bob!! sure", to: "bob", punctuation: ","),
                      "any run of punctuation counts, not just one mark")
    }

    func testReplyStillAddressesADraftThatMerelyOpensWithTheNickAsAWord() {
        // "will" is a nick and a word. Under any non-empty suffix the bare `will ` form is
        // NOT an address — the check demands punctuation, not just the nick.
        XCTAssertFalse(NickCompletion.isAddressed("will you come?", to: "will", punctuation: ":"))
    }

    func testUnderAnEmptyPunctuationTheBareNickFormCountsAsAddressed() {
        // With "space only" the addressed form and the nick-as-a-word form are the same
        // text; that ambiguity is the convention's, and Reply follows it rather than
        // producing `bob bob is wrong`.
        XCTAssertTrue(NickCompletion.isAddressed("bob is wrong", to: "bob", punctuation: ""))
    }

    func testReplyDoesNotMistakeALongerNickForTheAddressedOne() {
        // `bob_` is bob's ghost and `bobł` is someone else. The mark run has to exclude
        // nick characters — Unicode letters and the RFC 2812 specials — not just ASCII `\w`.
        XCTAssertFalse(NickCompletion.isAddressed("bob_: hi", to: "bob", punctuation: ":"))
        XCTAssertFalse(NickCompletion.isAddressed("bobł hi", to: "bob", punctuation: ":"))
        XCTAssertFalse(NickCompletion.isAddressed("bobł hi", to: "bob", punctuation: ""),
                       "and an empty setting must not let a letter pass as the space either")
        XCTAssertFalse(NickCompletion.isAddressed("bob2: hi", to: "bob", punctuation: ":"))
    }

    func testTheNickCharacterSetIsExactlyTheWebs() {
        // `\p{L}\p{N}` and nothing else. A COMBINING mark is not `\p{L}`, so the web reads
        // `bob` + punctuation here and this must agree — no real draft opens this way, which
        // is precisely why a quiet divergence would never be found again.
        XCTAssertTrue(NickCompletion.isAddressed("bob\u{0301} hi", to: "bob", punctuation: ":"))
        // `Ⅳ` is `Nl` and `²` is `No` — digits to `\p{N}`, but not to `.decimalDigits`.
        XCTAssertFalse(NickCompletion.isAddressed("bob\u{2163} hi", to: "bob", punctuation: ":"))
        XCTAssertFalse(NickCompletion.isAddressed("bob\u{00B2} hi", to: "bob", punctuation: ":"))
    }

    func testAMultiCharacterMarkIsRecognisedVerbatim() {
        // `->` ends in a nick special, so the punctuation-run arm can't see it; the
        // configured mark counts on its own, whatever it is.
        XCTAssertTrue(NickCompletion.isAddressed("bob-> sure", to: "bob", punctuation: "->"))
        XCTAssertFalse(NickCompletion.isAddressed("bob-x sure", to: "bob", punctuation: "->"))
    }

    func testAddressedTestIsCaseInsensitiveAndNeedsMoreThanTheNick() {
        XCTAssertTrue(NickCompletion.isAddressed("BOB: sure", to: "bob", punctuation: ":"))
        XCTAssertTrue(NickCompletion.isAddressed("bob: sure", to: "BOB", punctuation: ":"))
        XCTAssertFalse(NickCompletion.isAddressed("bob:", to: "bob", punctuation: ":"),
                       "the form is `nick: ` — a draft that is only the mark isn't addressed yet")
        XCTAssertFalse(NickCompletion.isAddressed("bob", to: "bob", punctuation: ""))
        XCTAssertFalse(NickCompletion.isAddressed("", to: "bob", punctuation: ":"))
        XCTAssertFalse(NickCompletion.isAddressed("bob: hi", to: "", punctuation: ":"))
    }
}
