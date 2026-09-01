// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Locks the @‑mention logic to the web client's `nickCompletion.ts`: speakers before
/// members, recency order, self excluded, departed speakers dropped in channels — plus
/// the token scanner and the addressing suffix the composer inserts.
final class NickCompletionTests: XCTestCase {

    private func speech(_ id: Int, _ nick: String, isSelf: Bool = false) -> Message {
        Message(id: id, type: .message, nick: nick, text: "hi", isSelf: isSelf)
    }

    // MARK: - Candidates

    func testRecentSpeakersLeadNewestFirstThenMembersAlphabetically() {
        let candidates = NickCompletion.candidates(
            messages: [speech(1, "alice"), speech(2, "bob")],
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
            messages: [speech(1, "Anna"), speech(2, "arthur")],
            members: [Member(nick: "Anna"), Member(nick: "arthur"), Member(nick: "AXEL"), Member(nick: "bob")],
            selfNick: nil,
            query: "a",
            isChannel: true
        )
        XCTAssertEqual(candidates, ["arthur", "Anna", "AXEL"])
    }

    func testYouAreNeverACandidate() {
        let candidates = NickCompletion.candidates(
            messages: [speech(1, "ME", isSelf: true), speech(2, "alice")],
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
        let history = [speech(1, "ghost"), speech(2, "alice")]
        let inChannel = NickCompletion.candidates(
            messages: history, members: [Member(nick: "alice")],
            selfNick: nil, query: "", isChannel: true
        )
        XCTAssertEqual(inChannel, ["alice"])

        let inDM = NickCompletion.candidates(
            messages: history, members: [],
            selfNick: nil, query: "", isChannel: false
        )
        XCTAssertEqual(inDM, ["alice", "ghost"])
    }

    func testOnlySpeechCountsAsSpeakingAndTheCapHolds() {
        let noisy: [Message] = [
            speech(1, "alice"),
            Message(id: 2, type: .join, nick: "joiner", text: nil),
            Message(id: 3, type: .notice, nick: "noticebot", text: "psa"),
            Message(id: 4, type: .action, nick: "bob", text: "waves"),
        ]
        let members = ["alice", "bob", "joiner", "noticebot", "carol", "dave"].map { Member(nick: $0) }
        let candidates = NickCompletion.candidates(
            messages: noisy, members: members, selfNick: nil, query: "", isChannel: true
        )
        XCTAssertEqual(candidates.count, 4, "capped at four")
        XCTAssertEqual(Array(candidates.prefix(2)), ["bob", "alice"],
                       "an action speaks; a join or notice does not")
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
        XCTAssertNil(NickCompletion.activeMention(in: "@al done", caret: 8),
                     "past the token's word there is no active mention")
        XCTAssertNil(NickCompletion.activeMention(in: "plain text", caret: 5))
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
