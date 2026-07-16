// swift-tools-version: 6.0
// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import PackageDescription

// The internal model + one client behind the UIKit app (lurker-ios#2). Extracting
// it into a package enforces the boundary the issue is about — the UI cannot reach
// into I/O — and lets the tricky, pure store/parser core be tested with `swift test`
// on the host, no simulator. Self-hosted and hosted are the SAME client differing
// only in base URL + auth (see `Backend`); there is deliberately no transport-adapter
// seam. Swift 5 language mode matches the app target (`SWIFT_VERSION = 5.0`).
let package = Package(
    name: "LurkerKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "LurkerKit", targets: ["LurkerKit"]),
    ],
    targets: [
        .target(name: "LurkerKit"),
        .testTarget(name: "LurkerKitTests", dependencies: ["LurkerKit"]),
    ],
    swiftLanguageModes: [.v5]
)
