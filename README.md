# Lurker for iOS

A native iOS client for [Lurker](https://github.com/amiantos/lurker), an IRC client with a server
that stays connected for you.

> **Status: prototype.** This is a spike, not the app. It exists to prove that Lurker's WebSocket +
> REST contract can be driven from a native client, and it does exactly enough to demonstrate that:
> sign in, list buffers, read a channel, send a message. Nothing else. See
> [Scope](#what-this-does-and-doesnt-do) before you get excited.

## What it proves

Lurker is a true bouncer: the client never touches IRC. The server does all the IRC work — parsing,
TLS, SASL, reconnect, history, highlight matching, ignore filtering — and speaks to clients in
high-level concepts (networks, buffers, messages, members) over one WebSocket plus a small REST
surface.

Until recently, though, the WebSocket authenticated by **cookie only**, so a native client couldn't
open one at all. [lurker#489](https://github.com/amiantos/lurker/issues/489) added bearer-token auth
to the upgrade, and this app is the end-to-end proof that it works:

1. `POST /api/auth/login/token` — password in, session token out, no browser in the loop.
2. `GET /api/networks` with `Authorization: Bearer <token>` — the same token authenticates REST.
3. `GET /ws` with the same bearer header on the **upgrade** — the thing browsers cannot do, and
   precisely why the web client is cookie-bound and native clients don't have to be.

A native session is an ordinary session: the bearer *is* the session token the web client's cookie
already carries, just handed to the app in a response body instead of a `Set-Cookie`.

## What this does (and doesn't) do

**Does:** sign in with a password · open the WebSocket · list buffers · open a channel and read its
backlog · send a message · render live incoming messages.

**Doesn't:** persist anything (state dies with the process, including your token — there's no
Keychain, so you sign in every launch) · reconnect or resume (`?since=`) · sort or group the buffer
list · show unread badges, member lists, DMs-as-first-class, uploads, search, highlights, settings,
or push · parse mIRC colors or link URLs · handle `/commands` · render joins, parts, quits, modes,
or topics.

## Architecture

The wire contract and domain model live in a local Swift package, **`LurkerKit`**, that the UIKit
app depends on. This is the split the 1.0 app is built on ([lurker-ios#2](https://github.com/amiantos/lurker-ios/issues/2)):
the UI can't reach into I/O, and the tricky, pure store/parser core is unit-tested on the host with
`swift test` — no simulator.

`LurkerKit/Sources/LurkerKit`:

- **`Model/`** — the domain the whole app renders: `Network` / `Buffer` / `Message` / `Member`, a
  `BufferKey` that folds target case, an `EventType` enum, and `Backend` (the configurable base URL
  + auth that makes self-hosted and hosted *one* client).
- **`Client/`** — `LurkerClient` owns the REST + WebSocket I/O and nothing else: it parses server
  bytes into typed `ServerFrame`s (via `FrameParser`) and delivers them on the main queue. It holds
  no domain state.
- **`Store/`** — `LurkerStore` folds `ServerFrame`s into an immutable `ChatState` with a pure
  reducer (shell-vs-hydrated backlog, live de-dupe, snapshot/name merge). This is the part the tests
  hammer.
- **`Session/`** — `ChatViewModel` owns the client + store for the app's lifetime and is the seam
  the later foundation issues hook into (persistence + 401-bounce in #3; reconnect/resume in #4).

The app itself is UIKit, programmatic — no storyboards, and no third-party dependencies (LurkerKit
uses only Foundation + Combine). The three view controllers — [`LoginViewController`](Lurker/LoginViewController.swift),
[`BufferListViewController`](Lurker/BufferListViewController.swift), and
[`ChatViewController`](Lurker/ChatViewController.swift) — observe `ChatState` and render it.

**Deliberately no transport-adapter seam.** The original plan called for one, but it was justified
almost entirely by a direct-IRC mode that has since been **dropped permanently**. Self-hosted and
hosted are the same client differing only in base URL and auth (see `Backend`), so the seam would
abstract over a second transport that will never exist. If one ever appears, extract it then, against
a real case.

## Running it

Requires a Lurker server you can reach, with a **password** set on your account — the token mint
endpoint is password-only, so a passkey-only account can't sign in yet.

Open `Lurker.xcodeproj` and run, or from the command line:

```sh
xcodebuild -project Lurker.xcodeproj -scheme Lurker -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Run the LurkerKit tests (the store + parser core) straight from the package — no simulator needed:

```sh
swift test --package-path LurkerKit
```

Point it at your server on the sign-in screen. The default is `http://localhost:8010`:

- The **Simulator shares the host's network**, so a dev server on your Mac is just `localhost` — no
  `10.0.2.2`-style indirection like the Android emulator needs. From a **physical device**, use the
  Mac's LAN IP instead (`.local` mDNS names are unreliable from iOS too).
- Use the **API server's port** (`8010` by default), not the Vite client dev port — that one only
  serves the web SPA and has no `/api` or `/ws`.

App Transport Security is disabled wholesale (`NSAllowsArbitraryLoads`) so a plain-HTTP dev server
works. That is a prototype convenience and must not survive into a shipping build.

## A note on the buffer list

On connect, the server ships one `backlog` frame per buffer — but for channels and DMs those frames
are **shells** with no messages in them. Lurker auto-focuses nothing on load, so it doesn't read a
buffer's history until the client actually opens it. The client sends `open-buffer` and the server
replies with a real backlog frame.

Get this wrong and you build a correct-looking buffer list where every channel is empty, which reads
as a bug but is the lazy-hydration design working as intended. It's the one piece of the contract
that isn't obvious from the frame names.

## License

[MPL-2.0](LICENSE), same as Lurker.
