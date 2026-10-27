// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing

@testable import LurkerKit

/// The allowlist every `UIApplication.open` in the app sits behind.
@Suite("External link schemes")
struct ExternalLinkTests {

    private func opens(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return ExternalLink.isOpenable(url)
    }

    @Test("the web and mail open")
    func webAndMailOpen() {
        #expect(opens("http://example.org/x"))
        #expect(opens("https://example.org/x"))
        #expect(opens("mailto:someone@example.org"))
    }

    @Test("scheme case is not a loophole")
    func schemeCaseIsFolded() {
        #expect(opens("HTTPS://example.org/x"))
        #expect(opens("MailTo:someone@example.org"))
    }

    /// ⚠ `ftp` is the one the matcher itself produces; the rest are what a peer could smuggle
    /// into a link the app did not build.
    @Test("every other scheme is refused")
    func otherSchemesAreRefused() {
        for link in [
            "ftp://files.example.org/x", "ftps://files.example.org/x", "tel:+15555550100",
            "sms:+15555550100", "file:///etc/passwd", "javascript:alert(1)",
            "chat.lurker:/oauth", "x-custom://whatever",
        ] {
            #expect(!opens(link), "\(link) must not leave the app")
        }
    }

    @Test("no scheme is no link")
    func schemelessIsRefused() {
        #expect(!opens("example.org/x"))
    }
}
