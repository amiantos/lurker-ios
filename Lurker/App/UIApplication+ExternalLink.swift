// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

extension UIApplication {
    /// The one door a link leaves the app through: `open`, behind `ExternalLink`'s allowlist.
    ///
    /// Every tap, menu action and "open in browser" in the app comes here rather than to
    /// `open(_:)` directly, so the allowlist is a fact about the app and not about whichever
    /// call sites happened to remember it. A refused scheme does nothing.
    func openExternal(_ url: URL) {
        guard ExternalLink.isOpenable(url) else { return }
        open(url)
    }
}
