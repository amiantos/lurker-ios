// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Which links a tap may hand to the system to open.
///
/// The renderer marks everything `URLMatcher` finds as tappable, and that includes `ftp://`
/// and `ftps://`, because the web client linkifies them (lurker's `shared/urlPattern.ts`) and
/// this app follows it. Matching is parity; OPENING is a different act. `UIApplication.open`
/// launches whichever app registered the scheme with an address a channel peer chose — stock
/// iOS has no FTP handler and ignores it, but a third-party FTP client or file manager would
/// come up pointed wherever the peer said. So every door a link leaves the app through checks
/// here first, and a refused scheme does nothing: the tap on an `ftp://` link is a tap on text.
public enum ExternalLink {
    /// The web and mail. Nothing the app renders as a link legitimately needs another scheme.
    public static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    public static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return openableSchemes.contains(scheme)
    }
}
