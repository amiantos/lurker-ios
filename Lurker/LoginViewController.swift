// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// Screen 1: password → session token. The Simulator shares the host's network, so a
/// local dev server is just `http://localhost:8010` (no 10.0.2.2 equivalent as on
/// Android). 8010 is the API/WS server — NOT the Vite client dev port.
///
/// Navigation away from here on success is driven by `SceneDelegate` observing the
/// session state; this screen just kicks off the sign-in.
final class LoginViewController: UIViewController {
    private let viewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

    private let backendControl = UISegmentedControl(items: ["Self-hosted", "Hosted (lurker.chat)"])
    private let serverField = UITextField()
    private let usernameField = UITextField()
    private let passwordField = UITextField()
    private let signInButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let scrollView = UIScrollView()

    private var backend: Backend { backendControl.selectedSegmentIndex == 1 ? .hosted : .selfHosted }

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

        let heading = UILabel()
        heading.text = "Lurker"
        heading.font = .preferredFont(forTextStyle: .largeTitle)

        let blurb = UILabel()
        blurb.text = "Signs in with a password and opens the WebSocket with a bearer token."
        blurb.font = .preferredFont(forTextStyle: .footnote)
        blurb.textColor = .secondaryLabel
        blurb.numberOfLines = 0

        // Prefill the last-used backend + server so a returning user (after sign-out)
        // doesn't retype them. The token itself is in the Keychain, not here.
        let savedBackend = UserPreferences.standard.lastBackend
        backendControl.selectedSegmentIndex = savedBackend == .hosted ? 1 : 0
        backendControl.addTarget(self, action: #selector(backendChanged), for: .valueChanged)

        configure(serverField, placeholder: "Server URL", text: UserPreferences.standard.lastServerURL)
        serverField.keyboardType = .URL
        serverField.autocapitalizationType = .none
        serverField.autocorrectionType = .no

        configure(usernameField, placeholder: savedBackend.identifierLabel)
        usernameField.autocapitalizationType = .none
        usernameField.autocorrectionType = .no
        usernameField.textContentType = savedBackend == .hosted ? .emailAddress : .username
        usernameField.keyboardType = savedBackend == .hosted ? .emailAddress : .default

        configure(passwordField, placeholder: "Password")
        passwordField.isSecureTextEntry = true
        passwordField.textContentType = .password

        signInButton.setTitle("Sign in", for: .normal)
        signInButton.configuration = .filled()
        signInButton.addTarget(self, action: #selector(signIn), for: .touchUpInside)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .systemRed
        statusLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [
            heading, blurb, backendControl, serverField, usernameField, passwordField, signInButton, spinner, statusLabel,
        ])
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

    /// Switching backends resets the server URL to that backend's default (unless the
    /// field was hand-edited off both defaults) and relabels the identifier field: hosted
    /// authenticates by account email, self-hosted by IRC-side username.
    @objc private func backendChanged() {
        if serverField.text == Backend.selfHosted.defaultURL || serverField.text == Backend.hosted.defaultURL {
            serverField.text = backend.defaultURL
        }
        usernameField.placeholder = backend.identifierLabel
        usernameField.textContentType = backend == .hosted ? .emailAddress : .username
        usernameField.keyboardType = backend == .hosted ? .emailAddress : .default
    }

    @objc private func signIn() {
        view.endEditing(true)
        statusLabel.text = nil
        let backend = self.backend
        let server = serverField.text ?? ""
        let identifier = usernameField.text ?? ""
        let password = passwordField.text ?? ""

        // Remember the backend + server for the next sign-in (prefill after sign-out).
        // Only a non-blank server, so a stray empty submit can't wipe a good value.
        UserPreferences.standard.set(lastBackend: backend)
        if !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserPreferences.standard.set(lastServerURL: server)
        }

        setBusy(true)
        // `@MainActor` is already implied here (the VC is main-isolated), but stated so
        // the post-`await` UI calls are unambiguously on the main actor.
        Task { @MainActor [weak self] in
            await self?.viewModel.login(backend: backend, server: server, identifier: identifier, password: password)
            // On success SceneDelegate swaps this screen out; on failure statusLabel
            // already carries the reason. Either way, stop the spinner.
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
}
