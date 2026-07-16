// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Network

/// Reports whether the device has a network path at all, so the indicator light can tell
/// "you have no internet" (red, and yours to fix) apart from "we're reconnecting" (amber,
/// and ours). The socket alone can't distinguish those — a drop looks identical either way.
///
/// This deliberately does NOT import LurkerKit. `Network` is both this framework's module
/// name and the name of LurkerKit's own model type, so a file importing both would make
/// every bare `Network` ambiguous. Keeping the monitor's dependency surface to a `Bool`
/// keeps the two apart, and is why `ChatViewModel.setReachable` takes a plain flag.
final class ReachabilityMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "chat.lurker.reachability")

    /// Begin watching. `onChange` fires on the main queue, once with the current path
    /// shortly after starting and then on every flip.
    func start(onChange: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            // `.requiresConnection` means a path exists but needs bringing up (on-demand
            // VPN); that isn't "no internet", so only `.unsatisfied` counts as offline.
            let reachable = path.status != .unsatisfied
            DispatchQueue.main.async { onChange(reachable) }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
