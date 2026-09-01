// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing

@testable import LurkerKit

/// The server's advertised upload cap: how it is read off the wire, how it reaches the store,
/// and what stands in before it has (#149 — the iOS half of lurker#627).
///
/// The whole point of the feature is that "the server didn't say" and "the server said a
/// number" are different states, so most of what is worth testing here is the silence.
@Suite("Upload cap")
@MainActor
struct UploadCapTests {

    // MARK: - What to compress against

    @Test("an advertised cap is used verbatim, envelope included")
    func advertisedCapIsUsedVerbatim() {
        // ⚠⚠ A FILE cap, not a body limit: the server has already subtracted the multipart
        // envelope (ENVELOPE_HEADROOM_BYTES, 64 KiB). Shaving anything off here would be the
        // same over-compression this replaced, just smaller.
        #expect(Uploads.compressionTarget(advertised: 25 * 1024 * 1024) == 25 * 1024 * 1024)
        #expect(Uploads.compressionTarget(advertised: 200 * 1024 * 1024) == 200 * 1024 * 1024)
    }

    @Test("no answer falls back to the Cloudflare-safe guess, rather than to no limit")
    func silenceFallsBackToTheGuess() {
        // The pre-snapshot window, and a self-hosted instance older than this app — both
        // normal. Neither may read as "uncapped", which would put a 400 MB clip on the wire.
        #expect(Uploads.compressionTarget(advertised: nil) == Uploads.fallbackMaxBytes)
        #expect(Uploads.fallbackMaxBytes == 90 * 1024 * 1024)
    }

    // MARK: - Reading it off the wire

    private func snapshotFrame(_ body: String) -> ServerFrame {
        FrameParser.parseWs(body)
    }

    @Test("the snapshot's cap is parsed")
    func snapshotCarriesTheCap() {
        let frame = snapshotFrame(
            #"{"kind":"snapshot","networks":[],"globalIgnores":[],"maxUploadBytes":26214400}"#
        )
        guard case let .snapshot(_, _, maxUploadBytes) = frame else {
            Issue.record("expected a snapshot, got \(frame)")
            return
        }
        #expect(maxUploadBytes == 26_214_400)
    }

    @Test("a snapshot from a server too old to advertise says nothing, not zero")
    func anOldSnapshotSaysNothing() {
        let frame = snapshotFrame(#"{"kind":"snapshot","networks":[],"globalIgnores":[]}"#)
        guard case let .snapshot(_, _, maxUploadBytes) = frame else {
            Issue.record("expected a snapshot, got \(frame)")
            return
        }
        #expect(maxUploadBytes == nil)
        #expect(Uploads.compressionTarget(advertised: maxUploadBytes) == Uploads.fallbackMaxBytes)
    }

    @Test("a non-positive cap is read as no answer")
    func nonsenseIsNotAnAnswer() {
        // The server never sends one. Taken at face value it would send every video down the
        // whole preset ladder to `.cannotCompressEnough`, which reads to the user as the app
        // refusing to upload rather than as a server that answered nonsense.
        for value in ["0", "-1"] {
            let frame = snapshotFrame(
                #"{"kind":"snapshot","networks":[],"globalIgnores":[],"maxUploadBytes":"# + value
                    + "}"
            )
            guard case let .snapshot(_, _, maxUploadBytes) = frame else {
                Issue.record("expected a snapshot")
                return
            }
            #expect(maxUploadBytes == nil, "\(value) is not a cap any file could satisfy")
        }
    }

    @Test("the settings frame carries the cap when the user changed it")
    func settingsFrameCarriesTheCap() {
        let frame = FrameParser.parseWs(
            #"{"kind":"settings","changes":{"uploads.image.max_upload_mb":12},"maxUploadBytes":12582912}"#
        )
        guard case let .settingsChanged(changes, maxUploadBytes) = frame else {
            Issue.record("expected a settings frame, got \(frame)")
            return
        }
        #expect(changes["uploads.image.max_upload_mb"] == .int(12))
        #expect(maxUploadBytes == 12_582_912)
    }

    @Test("a settings frame about anything else carries no cap")
    func anUnrelatedSettingsFrameCarriesNoCap() {
        let frame = FrameParser.parseWs(
            #"{"kind":"settings","changes":{"chat.consolidate_joins":true}}"#
        )
        guard case let .settingsChanged(_, maxUploadBytes) = frame else {
            Issue.record("expected a settings frame, got \(frame)")
            return
        }
        #expect(maxUploadBytes == nil, "absent here means unchanged, not uncapped")
    }

    // MARK: - Reaching the store

    @Test("the snapshot seeds the cap")
    func snapshotSeedsTheStore() {
        let state = LurkerStore.reduce(
            ChatState(), .snapshot([], globalIgnores: [], maxUploadBytes: 26_214_400))
        #expect(state.maxUploadBytes == 26_214_400)
    }

    @Test("a reconnect to an instance that no longer advertises returns to the fallback")
    func aSnapshotWithoutACapClearsIt() {
        // The snapshot is the cap's refresh point. Leaving the last server's number in force
        // would compress against a limit this one never claimed.
        var state = LurkerStore.reduce(
            ChatState(), .snapshot([], globalIgnores: [], maxUploadBytes: 26_214_400))
        state = LurkerStore.reduce(state, .snapshot([], globalIgnores: [], maxUploadBytes: nil))
        #expect(state.maxUploadBytes == nil)
        #expect(Uploads.compressionTarget(advertised: state.maxUploadBytes)
            == Uploads.fallbackMaxBytes)
    }

    @Test("a settings frame that carries a cap updates it")
    func aSettingsFrameRaisesTheCap() {
        var state = LurkerStore.reduce(
            ChatState(), .snapshot([], globalIgnores: [], maxUploadBytes: 26_214_400))
        state = LurkerStore.reduce(
            state,
            .settingsChanged(["uploads.image.max_upload_mb": .int(50)], maxUploadBytes: 52_428_800)
        )
        #expect(state.maxUploadBytes == 52_428_800)
    }

    @Test("⚠⚠ a settings frame about anything else must not clear the cap")
    func anUnrelatedSettingsFrameLeavesTheCapAlone() {
        // The trap this whole optional exists for. The cap rides the settings frame ONLY when
        // it was the thing that changed, so assigning it unconditionally would put the
        // compressor back on the 90 MiB guess every time the user flipped an unrelated switch
        // — and it would stay there until the next reconnect.
        var state = LurkerStore.reduce(
            ChatState(), .snapshot([], globalIgnores: [], maxUploadBytes: 209_715_200))
        state = LurkerStore.reduce(
            state, .settingsChanged(["chat.consolidate_joins": .bool(true)], maxUploadBytes: nil))
        #expect(state.maxUploadBytes == 209_715_200)
    }

    @Test("a fresh state has no cap, and compresses to the fallback")
    func aFreshStateHasNoCap() {
        #expect(ChatState().maxUploadBytes == nil)
        #expect(Uploads.compressionTarget(advertised: ChatState().maxUploadBytes)
            == Uploads.fallbackMaxBytes)
    }
}
