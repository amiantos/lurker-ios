// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Testing
import UniformTypeIdentifiers

@testable import LurkerKit

/// What Files will let you pick (#125).
///
/// ⚠⚠ Worth testing at all because the failure is INVISIBLE from the code: a missing type doesn't
/// error, it greys the file out in someone else's app. The assertions below are about conformance
/// facts the picker relies on, which are easy to get wrong by reasoning and cheap to just ask.
@Suite("Upload content types")
struct UploadContentTypesTests {

    @Test("offers the text dialects lurker#788 added, and the plain text that predates them")
    func offersText() {
        let types = UploadContentTypes.forOpening
        #expect(types.contains(.plainText), ".txt has always been uploadable and was never offered")
        #expect(types.contains(.json))
        #expect(types.contains(.image))
        #expect(types.contains(.movie))
    }

    @Test("markdown resolves, and is carried as an optional in case it ever does not")
    func markdownResolves() {
        // ⚠ The reason it is optional: no SDK constant, so it is built from an extension and the
        // initialiser is failable. If this ever stops resolving the picker must lose markdown, not
        // crash on the line that opens it.
        #expect(UploadContentTypes.markdown?.identifier == "net.daringfireball.markdown")
        #expect(UploadContentTypes.forOpening.contains { $0 == UploadContentTypes.markdown })
    }

    @Test("JSON is not covered by plain text, so both have to be listed")
    func jsonIsNotAPlainTextSubtype() {
        // ⚠⚠ The assumption that would have quietly greyed out every `.json`. `public.json`
        // conforms to `public.text`, which `public.plain-text` also conforms to — siblings, not
        // parent and child. The picker matches by conformance, so listing only `.plainText` would
        // have shipped a half-fix that looked complete.
        #expect(!UTType.json.conforms(to: .plainText))
        #expect(UTType.json.conforms(to: .text))
    }

    @Test("each dialect carries the mime the server wants, so the octet-stream fallback never fires")
    func dialectsDeriveTheRightMime() {
        // ⚠⚠ #125 flagged this as unknown — "worth confirming on-device what iOS actually returns
        // for `.md`, and if `preferredMIMEType` is nil there the fallback sends
        // `application/octet-stream`". It is not nil, so `AttachmentPicker.copy` derives the right
        // claim for all three and that fallback is unreachable for a Files pick.
        //
        // ⚠ Not that it would have mattered much: `classifyUpload` decides the CLASS from the
        // bytes and never from the claim, and the dialect LABEL is read from the filename first —
        // precisely because platforms disagree about `.md`. This one doesn't, which is worth
        // knowing rather than assuming.
        #expect(UploadContentTypes.markdown?.preferredMIMEType == "text/markdown")
        #expect(UTType.json.preferredMIMEType == "application/json")
        #expect(UTType.plainText.preferredMIMEType == "text/plain")
    }

    @Test("markdown IS plain text, so its entry is belt-and-braces rather than load-bearing")
    func markdownConformsToPlainText() {
        // Recorded rather than assumed: the entry stays (explicit beats inherited for something a
        // user notices only when it fails), but this says plainly that it is not what makes `.md`
        // pickable — so nobody later "simplifies" the list by deleting `.plainText` instead.
        #expect(UploadContentTypes.markdown?.conforms(to: .plainText) == true)
    }
}
