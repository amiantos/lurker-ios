// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import Foundation

/// The in-app notification sounds: the web's six (`public/sounds`), re-encoded as CAF.
///
/// System sounds rather than an `AVAudioPlayer`, for three things an alert sound has to get right
/// that a player would have to be talked into: the ring/silent switch silences them, they play
/// at the Ringer and Alerts volume rather than over the media volume, and they never touch the
/// audio session — so a ping neither stops the reader's music nor rewrites the `.playback`
/// session a video in the media viewer is using. The web's per-kind volume has no place in that
/// model; the phone's alert volume is the one the reader already set for this. Its 0 still means
/// silence (`StatusNotification.sound(in:)`).
@MainActor
enum NotificationSounds {
    /// Registered on first play and kept: a system sound is cheap to hold and the set is fixed.
    private static var ids: [String: SystemSoundID] = [:]

    static func play(_ name: String) {
        guard let id = soundID(name) else { return }
        AudioServicesPlaySystemSound(id)
    }

    private static func soundID(_ name: String) -> SystemSoundID? {
        if let id = ids[name] { return id }
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf") else { return nil }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError else { return nil }
        ids[name] = id
        return id
    }
}
