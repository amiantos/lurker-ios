// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// The add-network picker's data (#11): the bundled catalogue, the instance's own presets,
/// and what a pick fills into the form.
final class NetworkPresetTests: XCTestCase {

    // MARK: - The bundled catalogue

    func testTheCatalogueLoadsFromTheBundle() {
        // A resource that doesn't reach the bundle fails silently — an empty list and a
        // picker offering nothing but "Other Server…", which looks like a design decision
        // rather than a build problem.
        XCTAssertGreaterThan(BuiltinNetworks.all.count, 50)
        XCTAssertTrue(BuiltinNetworks.all.contains { $0.host == "irc.libera.chat" })
    }

    func testEveryEntryIsUsableAsAPreset() {
        // A row missing a host or a port is a row that fills the form with something that
        // can't connect — worse than not offering it, because the user tries it.
        for preset in BuiltinNetworks.all {
            XCTAssertFalse(preset.name.isEmpty)
            XCTAssertFalse(preset.host.isEmpty, preset.name)
            XCTAssertTrue((1...65535).contains(preset.port), preset.name)
        }
    }

    func testLurkerFriendlyNetworksComeFirst() {
        // The picker's default order has to be meaningful before anyone types, and the
        // networks where a new user can get help with this client come first.
        let firstNonLurker = BuiltinNetworks.all.firstIndex { !$0.tags.contains(BuiltinNetworks.lurkerTag) }
        let lastLurker = BuiltinNetworks.all.lastIndex { $0.tags.contains(BuiltinNetworks.lurkerTag) }
        XCTAssertNotNil(firstNonLurker)
        if let lastLurker, let firstNonLurker { XCTAssertLessThan(lastLurker, firstNonLurker) }
    }

    // MARK: - Suggested channels

    func testALurkerNetworkLeadsWithLurker() {
        let preset = NetworkPreset(
            name: "Libera.Chat", host: "irc.libera.chat", port: 6697, tls: true,
            defaultChannel: "#libera", tags: [BuiltinNetworks.lurkerTag]
        )
        XCTAssertEqual(preset.suggestedChannels, ["#lurker", "#libera"])
    }

    func testANetworkWeKnowNothingAboutSuggestsNothing() {
        // Absent is the honest answer: a wrong channel name lands a brand-new user somewhere
        // that doesn't exist, which is worse than landing them nowhere.
        let preset = NetworkPreset(name: "Somewhere", host: "irc.example", port: 6697, tls: true)
        XCTAssertTrue(preset.suggestedChannels.isEmpty)
    }

    func testAnInstancePresetsChannelsAreTheAdminsAlone() {
        // They run the place, so their word is the last word — we don't add #lurker to it.
        let preset = NetworkPreset(
            name: "Corp", host: "irc.corp.example", port: 6697, tls: true,
            recommendedChannels: ["#general", "#random"],
            tags: [BuiltinNetworks.lurkerTag], isInstance: true
        )
        XCTAssertEqual(preset.suggestedChannels, ["#general", "#random"])
    }

    func testTheNetworksOwnChannelIsNotRepeated() {
        let preset = NetworkPreset(
            name: "N", host: "h", port: 6697, tls: true,
            defaultChannel: "#LURKER", tags: [BuiltinNetworks.lurkerTag]
        )
        XCTAssertEqual(preset.suggestedChannels, ["#lurker"])
    }

    // MARK: - What a pick fills in

    func testAPickFillsEverythingButTheNick() {
        let preset = NetworkPreset(
            name: "Libera.Chat", host: "irc.libera.chat", port: 6697, tls: true,
            defaultChannel: "#libera", tags: [BuiltinNetworks.lurkerTag]
        )
        let draft = preset.draft()
        XCTAssertEqual(draft.name, "Libera.Chat")
        XCTAssertEqual(draft.host, "irc.libera.chat")
        XCTAssertEqual(draft.port, 6697)
        XCTAssertTrue(draft.tls)
        XCTAssertEqual(draft.defaultChannel, "#lurker, #libera")
        // The one thing the picker can't know, and the reason the form still opens.
        XCTAssertTrue(draft.nick.isEmpty)
        // ⚠ And it still verifies certificates — a prefill must not quietly relax the
        // security default. See `NetworkConfig.trustedCertificates`.
        XCTAssertTrue(draft.trustedCertificates)
    }

    func testAnUnknownNetworkStillOffersAChannelToJoin() {
        // Landing in an empty server buffer is what makes a new user think the app is broken.
        // `#chat` is a guess, and it's offered as an editable field, never joined silently.
        let draft = NetworkPreset(name: "N", host: "h", port: 6697, tls: true).draft()
        XCTAssertEqual(draft.defaultChannel, BuiltinNetworks.fallbackChannel)
    }

    // MARK: - Instance presets and the lockdown

    func testPresetsParseWithTheirChannelsAndPolicy() {
        let presets = FrameParser.parseNetworkPresets(##"""
        {"presets":[{"id":3,"name":"Corp","host":"irc.corp.example","port":6667,"tls":false,
        "saslLikelyRequired":true,"channels":["#general"]}],"allowUserDefined":false}
        """##)
        XCTAssertEqual(presets?.instance.count, 1)
        XCTAssertEqual(presets?.instance.first?.instanceID, 3)
        XCTAssertEqual(presets?.instance.first?.port, 6667)
        XCTAssertEqual(presets?.instance.first?.tls, false)
        XCTAssertEqual(presets?.instance.first?.recommendedChannels, ["#general"])
        XCTAssertEqual(presets?.instance.first?.isInstance, true)
        XCTAssertEqual(presets?.allowUserDefined, false)
    }

    func testAnOlderServerIsNotTreatedAsLockedDown() {
        // ⚠⚠ A server predating #298 sends no policy, and reading its silence as "locked
        // down" would hide the custom-server path — leaving an app that can't add a network
        // at all, which is the failure #11 exists to fix.
        XCTAssertEqual(FrameParser.parseNetworkPresets(##"{"presets":[]}"##)?.allowUserDefined, true)
        XCTAssertNil(FrameParser.parseNetworkPresets("not json"))
    }

    func testALockedDownInstanceOffersOnlyItsOwnNetworks() {
        // ⚠⚠ The policy is an allowlist of hosts: with `allowUserDefined` off, the enabled
        // presets are the entire allowed set. Every builtin would be a row whose only outcome
        // is a 403.
        let corp = NetworkPreset(name: "Corp", host: "irc.corp.example", port: 6697, tls: true, isInstance: true)
        let presets = NetworkPresets(instance: [corp], allowUserDefined: false)
        XCTAssertEqual(presets.offered, [corp])
    }

    func testAnOpenInstancePinsItsOwnNetworksAboveTheCatalogue() {
        let corp = NetworkPreset(name: "Corp", host: "irc.corp.example", port: 6697, tls: true, isInstance: true)
        let offered = NetworkPresets(instance: [corp], allowUserDefined: true).offered
        XCTAssertEqual(offered.first, corp)
        XCTAssertGreaterThan(offered.count, BuiltinNetworks.all.count)
    }

    func testAnAdminsOwnListingWinsOverTheBuiltinForTheSameHost() {
        // Otherwise the same server appears twice under two names, and one of the two carries
        // the admin's recommended channels while the other doesn't.
        let libera = NetworkPreset(
            name: "Our Libera", host: "irc.libera.chat", port: 6697, tls: true, isInstance: true
        )
        let offered = NetworkPresets(instance: [libera], allowUserDefined: true).offered
        XCTAssertEqual(offered.filter { $0.host == "irc.libera.chat" }, [libera])
    }
}
