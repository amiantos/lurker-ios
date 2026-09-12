// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// Screen 1: the server's address, then that server's own sign-in and approval pages in a
/// browser sheet (`BrowserSignIn`). The app never handles the password.
///
/// Navigation away from here on success is driven by `SceneDelegate` observing the
/// session state; this screen just kicks off the sign-in.
final class LoginViewController: UIViewController {
    private let viewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

    private let serverField = UITextField()
    private let signInButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let scrollView = UIScrollView()
    /// The sheet in progress, held until the sign-in finishes.
    private var browser: BrowserSignIn?

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Lurker"
        // Explicitly never: the navigation bar prefers large titles for the buffer list's
        // sake, and inheriting that here would stack a large "Lurker" in the bar directly on
        // top of the large "Lurker" this screen already draws as its own heading.
        navigationItem.largeTitleDisplayMode = .never

        let heading = UILabel()
        heading.text = "Lurker"
        heading.font = .preferredFont(forTextStyle: .largeTitle)

        let blurb = UILabel()
        blurb.text = "Enter your Lurker server. For lurker.chat, that's app.lurker.chat."
        blurb.font = .preferredFont(forTextStyle: .footnote)
        blurb.textColor = .secondaryLabel
        blurb.numberOfLines = 0

        // Prefill the last-used server so a returning user (after sign-out) doesn't retype
        // it. The token itself is in the Keychain, not here.
        configure(serverField, placeholder: "Server", text: UserPreferences.standard.lastServerURL)
        serverField.keyboardType = .URL
        serverField.textContentType = .URL
        serverField.autocapitalizationType = .none
        serverField.autocorrectionType = .no
        serverField.returnKeyType = .go

        signInButton.setTitle("Sign in", for: .normal)
        signInButton.configuration = .filled()
        signInButton.addTarget(self, action: #selector(signIn), for: .touchUpInside)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = Palette.bad
        statusLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [heading, blurb, serverField, signInButton, spinner, statusLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(24, after: blurb)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // A scroll view so the keyboard never covers a field: on a short screen (or with
        // the keyboard up) the whole form scrolls, and we inset for the keyboard below.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Vertical anchors to the content guide (scrollable); horizontal anchors to the
            // frame guide (fixed to the viewport, so there's no sideways scroll or offset).
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 32),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -24),
        ])

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(keyboardWillChange),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification, object: nil
        )

        // The reason a sign-in failed, or why a prior session ended (a mid-session 401
        // bounces here with an explanation), lands in this label.
        viewModel.statusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in self?.statusLabel.text = message }
            .store(in: &cancellables)
    }

    // MARK: - Keyboard

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let overlap = max(0, view.bounds.maxY - view.convert(frame, from: nil).minY)
        scrollView.contentInset.bottom = overlap
        scrollView.verticalScrollIndicatorInsets.bottom = overlap
    }

    @objc private func keyboardWillHide() {
        scrollView.contentInset.bottom = 0
        scrollView.verticalScrollIndicatorInsets.bottom = 0
    }

    private func configure(_ field: UITextField, placeholder: String, text: String = "") {
        field.placeholder = placeholder
        field.text = text
        field.borderStyle = .roundedRect
        field.delegate = self
        field.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    @objc private func signIn() {
        guard browser == nil, let window = view.window else { return }
        view.endEditing(true)
        statusLabel.text = nil
        let server = serverField.text ?? ""

        // Remember the server for the next sign-in (prefill after sign-out). Only a non-blank
        // one, so a stray empty submit can't wipe a good value.
        if !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserPreferences.standard.set(lastServerURL: server)
        }

        let browser = BrowserSignIn(anchor: window)
        self.browser = browser
        setBusy(true)
        // Named for the device, so the member can tell an iPhone from an iPad in the web
        // client's list of authorized apps.
        let appName = "Lurker for \(UIDevice.current.model)"
        Task { @MainActor [weak self] in
            await self?.viewModel.signIn(server: server, appName: appName) { url in
                await browser.authorize(url)
            }
            // On success SceneDelegate swaps this screen out; on failure statusLabel
            // already carries the reason. Either way, stop the spinner.
            self?.browser = nil
            self?.setBusy(false)
        }
    }

    private func setBusy(_ busy: Bool) {
        signInButton.isEnabled = !busy
        busy ? spinner.startAnimating() : spinner.stopAnimating()
    }
}

extension LoginViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        // Scroll the focused field above the keyboard, once the inset has been applied.
        DispatchQueue.main.async {
            let rect = textField.convert(textField.bounds, to: self.scrollView).insetBy(dx: 0, dy: -20)
            self.scrollView.scrollRectToVisible(rect, animated: true)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        signIn()
        return true
    }
}
