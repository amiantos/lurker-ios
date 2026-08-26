// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Testing
import UniformTypeIdentifiers

@testable import LurkerKit

/// What Files will let you pick (#125).
///
/// ⚠⚠ Worth testing at all because the failure is INVISIBLE from the code: a missing type doesn't
/// error, it greys the file out in somebody else's app.
///
/// ⚠⚠ These settle the **host** UTI database — CI runs `swift test` on macOS — and iOS declares its
/// own. That is close to the same database in practice, and every identifier below is
/// system-declared rather than app-declared, but it is not proof about the device: the one thing
/// #125 explicitly asked to confirm on-device (what `.md` reports as its mime) is exactly the kind
/// of thing that could differ and leave this suite green. Treated as a floor, with the device check
/// on the QA list.
@Suite("Upload content types")
struct UploadContentTypesTests {

    @Test("offers text as a family, not a hand-picked set of dialects")
    func offersTheTextFamily() {
        let types = UploadContentTypes.forOpening
        #expect(types.contains(.text))
        #expect(types.contains(.image))
        #expect(types.contains(.movie))
    }

    @Test("naming the parent covers every dialect, including the ones a hand-written list missed")
    func textCoversTheDialects() {
        // ⚠⚠ The bug this list started with. `[.plainText, .json]` reads as complete and is not:
        // `public.json` conforms to `public.text` but NOT to `public.plain-text` — siblings, not
        // parent and child — so plain text alone greys out every `.json`, and `.yaml` (also a
        // sibling) stays greyed out even with `.json` added by hand. The picker matches by
        // conformance, so a wrong guess about the hierarchy is invisible until somebody cannot
        // select a file.
        #expect(!UTType.json.conforms(to: .plainText), "the trap: json is not a plain-text subtype")
        #expect(!UTType.yaml.conforms(to: .plainText))
        for dialect in [UTType.plainText, .json, .yaml, .commaSeparatedText] {
            #expect(dialect.conforms(to: .text), "\(dialect.identifier) must be offered")
        }
        #expect(UTType(filenameExtension: "md")?.conforms(to: .text) == true)
    }

    @Test("the dialects lurker#788 named carry the mime the server keys on")
    func dialectsDeriveTheRightMime() {
        // #125 asked what iOS returns for `.md`, noting a nil would mean claiming octet-stream.
        // It is not nil here, so `AttachmentPicker.copy` derives the right claim and the server's
        // `TEXT_DIALECT_BY_MIME` matches it directly.
        #expect(UTType(filenameExtension: "md")?.preferredMIMEType == "text/markdown")
        #expect(UTType.json.preferredMIMEType == "application/json")
        #expect(UTType.plainText.preferredMIMEType == "text/plain")
    }

    @Test("plenty of offered text has NO registered mime, which is why the fallback matters")
    func muchOfferedTextHasNoMime() {
        // ⚠⚠ The finding that made the octet-stream fallback load-bearing rather than unreachable.
        // Each of these is offered by `.text` and reports no `preferredMIMEType`, so without
        // `AttachmentPicker.copy`'s text-aware fallback each would be claimed as
        // `application/octet-stream` — which the server does NOT exempt from its SVG probe. A
        // shell script or build log containing `<svg ` in its first kilobyte is then classified
        // `image/svg+xml`: a 415 on hosted, and on self-host stored and served as active SVG.
        //
        // Asserted as an existence proof over a sample rather than a fixed list, so a future SDK
        // registering mimes for some of them doesn't fail the suite for the wrong reason.
        //
        // ⚠ And an empty result would NOT mean the fallback became unreachable — it would only
        // mean these five gained mimes. `.text` admits far more than the suite names, so the
        // fallback has to stay whatever this says. The message says that, because a misleading
        // diagnostic on an OS bump is how a correct guard gets deleted.
        let mimeless = ["log", "sh", "c", "h", "swift"].filter { ext in
            guard let t = UTType(filenameExtension: ext) else { return false }
            return t.conforms(to: .text) && t.preferredMIMEType == nil
        }
        #expect(
            !mimeless.isEmpty,
            """
            These five text types gained registered mimes. That does NOT mean the text-aware \
            fallback in AttachmentPicker.copy is now dead code — `.text` admits far more than \
            this sample — so update the sample, do not remove the fallback.
            """)
    }

    @Test("SVG is offered by .image regardless, so naming .text admits nothing new")
    func svgIsNotWidenedByText() {
        // ⚠ `.text` sounds like it would newly admit SVG — the one text-conforming type the server
        // treats as an image. It does conform, and it was already offered by `.image`, so this
        // change moves nothing. Recorded because "did we just start allowing SVG?" is the first
        // fair question to ask of widening a picker.
        #expect(UTType.svg.conforms(to: .text))
        #expect(UTType.svg.conforms(to: .image))
    }
}
