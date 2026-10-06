// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import LurkerKit

@Suite("Image animation (sweep L13)")
struct ImageAnimationTests {
    @Test("the formats that animate play when they hold several images")
    func animationsPlay() {
        for type in ["com.compuserve.gif", "public.png", "org.webmproject.webp", "public.heics", "public.avis"] {
            #expect(ImageAnimation.plays(frameCount: 12, typeIdentifier: type), "\(type)")
        }
    }

    @Test("⚠ a still with several images never plays")
    func stillsWithSeveralImagesDont() {
        // An Ultra HDR photo reads as the photo and its gain map; played, it flickered between them.
        #expect(!ImageAnimation.plays(frameCount: 2, typeIdentifier: "public.jpeg"))
        #expect(!ImageAnimation.plays(frameCount: 2, typeIdentifier: "public.mpo-image"))
        #expect(!ImageAnimation.plays(frameCount: 3, typeIdentifier: "public.tiff"))
        #expect(!ImageAnimation.plays(frameCount: 2, typeIdentifier: "com.microsoft.ico"))
        #expect(!ImageAnimation.plays(frameCount: 3, typeIdentifier: "public.heic"))
        #expect(!ImageAnimation.plays(frameCount: 2, typeIdentifier: "public.avif"))
    }

    @Test("one image, or a type ImageIO couldn't name, is a still")
    func oneImageOrNoTypeIsAStill() {
        #expect(!ImageAnimation.plays(frameCount: 1, typeIdentifier: "com.compuserve.gif"))
        #expect(!ImageAnimation.plays(frameCount: 12, typeIdentifier: nil))
    }
}
