# Lurker for iOS

The native iOS client for [Lurker](https://github.com/amiantos/lurker) — an IRC client with a
server that stays connected for you. The app is a thin client over the Lurker server (self-hosted,
or the hosted **lurker.chat** service): the server does all the IRC work — TLS, SASL, reconnect,
history, highlights, ignore filtering — and speaks to the app in high-level concepts (networks,
buffers, messages, members) over one WebSocket plus a small REST surface.

## Fully native, zero dependencies

Written in Swift with UIKit, using **only Apple frameworks** — no third-party libraries, nothing to
resolve before a build:

- **`URLSession` / `URLSessionWebSocketTask`** — REST + the bearer-authenticated WebSocket
- **`Combine`** — observing state into the UI
- **`Security`** (Keychain) — the session token at rest
- **`Foundation`** — parsing, dates, everything else

## Architecture

The wire contract and domain model live in a local Swift package, **`LurkerKit`**, that the app
depends on:

- **`Model`** — `Network` / `Buffer` / `Message` / `Member` / `Backend`
- **`Client`** — the one client that owns the REST + WebSocket I/O and parses bytes into typed frames
- **`Store`** — a pure reducer folding those frames into an immutable `ChatState`
- **`Rendering`** — mIRC formatting, per-nick coloring, URL linking

It's all pure and unit-tested (`swift test`, no simulator). The UIKit app is a thin shell that
observes `ChatState` and renders it. Self-hosted and hosted are the *same* client differing only in
base URL and auth — there is deliberately no transport-adapter seam.

The app target (`Lurker/`) is grouped by UI layer. There is no `Model` folder here on purpose —
every model lives in `LurkerKit`, and a type that needs to exist in both is a sign it belongs in the
package:

- **`App`** — the delegates, and nothing else
- **`Navigation`** — how screens reach each other, plus the nav bar's shared title pill
- **`Screens`** — one view controller per screen
- **`Views`** — everything a screen composes: cells, the composer, the floating pills, banners
- **`Rendering`** — model → `NSAttributedString` and the color palette; the UIKit half of the job
  `LurkerKit/Rendering` does on plain strings
- **`Services`** — the platform capabilities the app wraps: photo/file picking, image and video
  transcoding, push registration, reachability, `UserDefaults`

The folders are plain directories: the target is a synchronized group, so adding or moving a file
needs no project-file edit.

## Building

Requires a Lurker server you can reach, with a **password** on your account (the native token
endpoint is password-only, so a passkey-only account can't sign in yet). Open `Lurker.xcodeproj` and
run, or from the command line:

```sh
xcodebuild -project Lurker.xcodeproj -scheme Lurker -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# The LurkerKit tests (store, parser, rendering) run on the host — no simulator:
swift test --package-path LurkerKit
```

On the sign-in screen, point it at your server. The default is `http://localhost:8010` — the API/WS
port, **not** the Vite client dev port. The Simulator shares the host's network, so a dev server on
your Mac is just `localhost`; from a physical device, use the Mac's LAN IP.

## License

[MPL-2.0](LICENSE), same as Lurker.
