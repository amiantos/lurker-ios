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
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])

        // The reason a sign-in failed, or why a prior session ended (a mid-session 401
        // bounces here with an explanation), lands in this label.
        viewModel.statusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in self?.statusLabel.text = message }
            .store(in: &cancellables)
    }

    private func configure(_ field: UITextField, placeholder: String, text: String = "") {
        field.placeholder = placeholder
        field.text = text
        field.borderStyle = .roundedRect
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
        UserPreferences.standard.set(lastBackend: backend)
        UserPreferences.standard.set(lastServerURL: server)

        setBusy(true)
        Task { [weak self] in
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
