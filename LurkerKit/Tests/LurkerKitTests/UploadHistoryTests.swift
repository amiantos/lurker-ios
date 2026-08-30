// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing

@testable import LurkerKit

/// Reading a page of `GET /api/uploads`, and the mime→kind rule the rows are drawn by (#138).
@Suite("Upload history")
struct UploadHistoryTests {

    // MARK: - Kinds

    @Test("a JSON upload is TEXT, which no prefix match would say")
    func jsonIsText() {
        // ⚠⚠ The reason this rule is a shared table rather than `mime.hasPrefix("text/")`.
        // `application/json` is a text file IANA files under `application/` (RFC 8259 registers
        // it; there is no `text/json`), so a prefix match misses it — and the row would be drawn
        // with a generic glyph while the server files it under the Text filter (lurker#788).
        #expect(UploadKind.text.matches(mime: "application/json"))
        #expect(UploadKind.of(mime: "application/json") == .text)
    }

    @Test("prefixes cover the ordinary cases")
    func prefixesMatch() {
        #expect(UploadKind.of(mime: "image/webp") == .image)
        #expect(UploadKind.of(mime: "video/mp4") == .video)
        #expect(UploadKind.of(mime: "audio/mpeg") == .audio)
        #expect(UploadKind.of(mime: "text/markdown") == .text)
    }

    @Test("a mime no kind covers is nil, not a wrong guess")
    func unknownMimeHasNoKind() {
        // A PDF is a real upload the server accepts and no filter chip claims. Forcing it under
        // one would put it in a list it does not belong to, which is worse than an unfiltered row.
        #expect(UploadKind.of(mime: "application/pdf") == nil)
        #expect(UploadKind.of(mime: nil) == nil)
        // ⚠ And `application/` alone must not fall under text on the strength of the json entry.
        #expect(!UploadKind.text.matches(mime: "application/zip"))
    }

    // MARK: - Parsing

    @Test("a live row carries everything the grid draws")
    func parsesALiveRow() {
        let page = FrameParser.parseUploads(
            """
            {"items":[{"id":41,"provider":"local","url":"https://lurker.test/uploads/k.webp",
            "filename":"cat.png","mime":"image/webp","byte_size":8192,"width":100,"height":80,
            "created_at":"2026-08-20T11:04:05.123Z","favorite":true,"can_delete":true,
            "thumbnail_url":"/api/uploads/41/thumb"}],"providers":["local"],
            "maxUploadBytes":104857600}
            """
        )
        let row = try! #require(page.items.first)
        #expect(row.id == 41)
        #expect(row.url == "https://lurker.test/uploads/k.webp")
        #expect(row.filename == "cat.png")
        #expect(row.byteSize == 8192)
        #expect(row.favorite)
        #expect(row.canDelete)
        #expect(row.thumbnailPath == "/api/uploads/41/thumb")
        #expect(!row.removed)
        #expect(row.kind == .image)
        #expect(row.createdAt != nil)
    }

    @Test("a moderated tombstone reads back dead, not merely flagged")
    func parsesATombstone() {
        // ⚠⚠ The server drops `can_delete` and every thumbnail for a removed row because the
        // bytes are gone. Nothing may default those into looking live — a delete button on a
        // tombstone is one the route answers 409 to, and a thumbnail path is a dead fetch.
        let page = FrameParser.parseUploads(
            """
            {"items":[{"id":9,"provider":"catbox","url":"https://files.test/x.png",
            "filename":"x.png","mime":"image/png","byte_size":10,"created_at":"2026-08-01T00:00:00Z",
            "favorite":true,"removed":true}]}
            """
        )
        let row = try! #require(page.items.first)
        #expect(row.removed)
        #expect(!row.canDelete)
        #expect(row.thumbnailPath == nil)
        // ⚠ The star SURVIVES a takedown — the server keeps it, so the state comes back if the
        // row is ever restored. Which means a tombstone can arrive already starred, and the one
        // affordance it must still offer is unstarring: hiding it would strand that star with no
        // way in any UI to clear it.
        #expect(row.favorite)
    }

    @Test("a nameless row says so rather than showing its storage key")
    func pastedRowHasNoFilename() {
        let page = FrameParser.parseUploads(
            #"{"items":[{"id":2,"url":"https://files.test/ab12.png","filename":null,"mime":"image/png"}]}"#
        )
        let row = try! #require(page.items.first)
        #expect(row.filename == nil)
        #expect(row.displayName == "(pasted)")
    }

    @Test("a body that isn't a page is an empty page, not a crash")
    func garbageIsEmpty() {
        #expect(FrameParser.parseUploads("not json").items.isEmpty)
        #expect(FrameParser.parseUploads(#"{"items":[]}"#).items.isEmpty)
    }
}
