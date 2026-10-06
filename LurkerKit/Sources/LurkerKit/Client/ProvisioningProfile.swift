// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Which APNs gateway this build's device token belongs to, read from how the build was
/// actually signed rather than from a compile-time flag: a Release build installed from
/// Xcode is still signed for development, and a Debug build can be signed for ad hoc.
///
/// A development or ad hoc build carries its provisioning profile as
/// `embedded.mobileprovision`; the App Store and TestFlight strip it, and those builds are
/// production. The profile is a CMS-signed envelope around a plain XML plist, so the plist
/// can be read out of it without verifying the signature (the OS already did).
public enum ProvisioningProfile {
    public static func apnsEnvironment(embeddedProfile: Data?) -> APNsEnvironment {
        guard let embeddedProfile else { return .production }
        // A profile without the entitlement belongs to a build that can't take pushes at all;
        // development is the honest guess for anything provisioned outside the store.
        guard let value = entitlements(in: embeddedProfile)?["aps-environment"] as? String else {
            return .development
        }
        return value == "production" ? .production : .development
    }

    static func entitlements(in profile: Data) -> [String: Any]? {
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: profile.subdata(in: start.lowerBound..<end.upperBound), format: nil
              ) as? [String: Any]
        else { return nil }
        return plist["Entitlements"] as? [String: Any]
    }
}
