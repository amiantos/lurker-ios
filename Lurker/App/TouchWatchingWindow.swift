// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// Something that wants to see touches before the window hands them out.
@MainActor
protocol WindowTouchWatcher: AnyObject {
    func windowWillSend(_ touches: Set<UITouch>)
}

/// The app's window: it shows each touch to whoever asked before dispatching it.
///
/// ⚠ This exists for one iOS bug. Since iOS 17.1, while the keyboard has an autocorrection
/// pending — the word highlighted — the next tap anywhere outside the text accepts the
/// correction and is never delivered to the view under it (Apple's forums thread 759463,
/// FB13418977; DTS: "no workaround"). The completion chips are shown exactly while a word is
/// half typed, which is when a correction is pending, so their taps were the ones lost
/// (lurker#1401). A view never sees a touch the system took, but the window does: every touch
/// event passes through `sendEvent` first. `SuggestionsView` watches from here and makes the
/// pick itself.
final class TouchWatchingWindow: UIWindow {
    private let watchers = NSHashTable<AnyObject>.weakObjects()

    func addTouchWatcher(_ watcher: WindowTouchWatcher) { watchers.add(watcher) }
    func removeTouchWatcher(_ watcher: WindowTouchWatcher) { watchers.remove(watcher) }

    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches, watchers.count > 0, let touches = event.allTouches {
            for case let watcher as WindowTouchWatcher in watchers.allObjects {
                watcher.windowWillSend(touches)
            }
        }
        super.sendEvent(event)
    }
}
