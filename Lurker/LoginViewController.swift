// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// Screen 1: password → session token. The Simulator shares the host's network, so
/// a local dev server is just `http://localhost:8010` (no 10.0.2.2 equivalent as on
/// Android). 8010 is the API/WS server — NOT the Vite client dev port, which only
/// serves the web SPA and has no /api or /ws.
final class LoginViewController: UIViewController {
    private let client: LurkerClient

    private let serverField = UITextField()
    private let usernameField = UITextField()
    private let passwordField = UITextField()
    private let signInButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(client: LurkerClient) {
        self.client = client
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
        blurb.text = "Prototype client — signs in with a password and opens the WebSocket with a bearer token."
        blurb.font = .preferredFont(forTextStyle: .footnote)
        blurb.textColor = .secondaryLabel
        blurb.numberOfLines = 0

        configure(serverField, placeholder: "Server URL", text: "http://localhost:8010")
        serverField.keyboardType = .URL
        serverField.autocapitalizationType = .none
        serverField.autocorrectionType = .no

        configure(usernameField, placeholder: "Username")
        usernameField.autocapitalizationType = .none
        usernameField.autocorrectionType = .no
        usernameField.textContentType = .username

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
            heading, blurb, serverField, usernameField, passwordField, signInButton, spinner, statusLabel,
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

        client.onStatus = { [weak self] message in
            self?.statusLabel.text = message
        }
    }

    private func configure(_ field: UITextField, placeholder: String, text: String = "") {
        field.placeholder = placeholder
        field.text = text
        field.borderStyle = .roundedRect
        field.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    @objc private func signIn() {
        view.endEditing(true)
        statusLabel.text = nil
        setBusy(true)

        client.login(
            server: serverField.text ?? "",
            username: usernameField.text ?? "",
            password: passwordField.text ?? ""
        ) { [weak self] ok in
            guard let self else { return }
            self.setBusy(false)
            guard ok else { return } // onStatus already carries the reason
            let buffers = BufferListViewController(client: self.client)
            self.navigationController?.setViewControllers([buffers], animated: true)
        }
    }

    private func setBusy(_ busy: Bool) {
        signInButton.isEnabled = !busy
        busy ? spinner.startAnimating() : spinner.stopAnimating()
    }
}
