// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

extension UITraitCollection {

    /// Whether the system puts this screen's bars in a vertical rail down one side — an iPhone
    /// Duo's — rather than across the top and bottom.
    ///
    /// A rail runs the full height of the display, so it has room for a column of buttons that a
    /// phone-width bar would have to fold into a "…" menu. Screens read this to lay their items out
    /// flat when it's true.
    var hasVerticalBar: Bool {
        if #available(iOS 27.1, *) { return verticalBarEdge != .unspecified }
        return false
    }
}

extension UIViewController {

    /// Call `handler` whenever `hasVerticalBar` may have changed — the system names the traits it
    /// depends on, so this doesn't have to guess at them.
    func registerForVerticalBarChanges(_ handler: @escaping (Self) -> Void) {
        guard #available(iOS 27.1, *) else { return }
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) {
            (controller: Self, _: UITraitCollection) in
            handler(controller)
        }
    }
}
