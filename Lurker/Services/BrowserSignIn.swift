// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import AuthenticationServices
import LurkerKit
import UIKit

/// The server's sign-in and approval pages, in the system browser sheet. LurkerKit runs the
/// OAuth flow and asks this for one thing: show a page, and say where it sent the browser back.
///
/// Ephemeral, so the sheet shares no cookies with Safari: a sign-in never lands on whichever
/// account Safari last used, and signing out of the app leaves no web session behind. It also
/// skips the system alert about sharing website data. The cost is typing a password (or using a
/// passkey) each time, which is rare, since the token never expires.
final class BrowserSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: UIWindow
    /// Retained while the sheet is up; a released session is cancelled.
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL?, Never>?

    init(anchor: UIWindow) {
        self.anchor = anchor
    }

    /// The address the page redirected to, or nil when the sheet closed without one.
    func authorize(_ url: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(OAuth.callbackScheme)
            ) { @Sendable callbackURL, error in
                if let error, (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                    NSLog("[sign-in] the browser sheet failed: %@", error.localizedDescription)
                }
                Task { @MainActor in self.finish(callbackURL) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() { finish(nil) }
        }
    }

    /// Resumes once, whichever of a failed start and the completion handler comes first.
    private func finish(_ url: URL?) {
        session = nil
        continuation?.resume(returning: url)
        continuation = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
