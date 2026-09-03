<div align="center">

<img src="assets/images/logo.svg" width="112" height="112" alt="AxiOm icon" />

# AxiΩm

**Freedom is an axiom.**

A VPN client for people living behind blocks — four ways around them, a server picker that speaks countries instead of outbound lists, and the numbers that actually matter on one screen.

[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows-3B5BDB?style=flat-square)](#installation)
[![Flutter](https://img.shields.io/badge/built%20with-Flutter-02569B?style=flat-square&logo=flutter&logoColor=white)](#tech-stack)
[![Based on Hiddify](https://img.shields.io/badge/based%20on-Hiddify-6E56CF?style=flat-square)](https://github.com/hiddify/hiddify-app)
[![License](https://img.shields.io/badge/license-Hiddify%20Extended%20GPLv3-C26B45?style=flat-square)](LICENSE.md)
[![Latest release](https://img.shields.io/github/v/release/AxiOm-Labs-Inc/AxiOm-v2?style=flat-square&color=E8A23D)](https://github.com/AxiOm-Labs-Inc/AxiOm-v2/releases/latest)

**[axiom.arcohouse.space](https://axiom.arcohouse.space/)** — what the service is, plans and downloads

</div>

---

## What AxiOm changes

AxiOm is built on [Hiddify](https://github.com/hiddify/hiddify-app), which is a superb
general-purpose proxy frontend: it speaks every protocol and exposes every knob. That
generality is exactly what makes it hard to hand to someone whose only question is
"why doesn't Instagram open." AxiOm keeps the engine and rebuilds the part the user
touches, around one assumption — **the person opening this app is not a network engineer,
and today they are probably annoyed.**

Concretely, not as slogans:

- **A server picker that speaks countries, not outbounds.** Stock Hiddify shows the raw
  outbound list from your subscription — a wall of strings like `🇳🇱 NL-ws-cf-01`. AxiOm
  reads the same list and folds it into a cascade: **country → protocol → transport**,
  with an **Auto (fastest)** mode on top. The choice survives restarts, so the app opens
  where you left it.
- **Ping you can trust because it's fresh.** Latency is measured when you open a dropdown
  and refreshed every 30 seconds while it's open — not once at import and then frozen for
  a week. "Fastest" means fastest now.
- **Several ways around blocks, switchable in two taps.** VLESS over WebSocket (through
  Cloudflare) or Reality on TCP, Hysteria2 over QUIC, and Naive disguised as HTTP/2 TLS —
  all behind the same picker, each labelled in plain words. When one transport starts
  getting throttled, moving off it is a choice from a list, not a re-import of a profile.
- **WARP, when it is on, says so.** With the Cloudflare WARP detour enabled the picker
  shows it as an extra layer and still lists the servers underneath, instead of quietly
  changing what "connected" means.
- **The four numbers that matter, on the main screen.** Traffic, days left, ping, and a
  **live device counter** for the subscription — the last one answers "why am I being
  disconnected" without a support ticket. Unlimited traffic or no expiry render as `∞`
  instead of a fake big number.
- **A connection timer that survives the process being killed.** Android kills background
  apps; the tunnel keeps running. The timer is reconstructed from the connection start
  time, so it shows how long you have actually been connected, not how long the widget
  has been alive.
- **Russian sites stay Russian.** `.ru` domains and Russian IP ranges are routed direct,
  IPv6 is off by default. Banks and government services keep working while everything
  else goes through the tunnel — no toggling the VPN off and on all day.
- **The subscription lives in the app.** Log in with Telegram once and your subscriptions
  are imported into profiles automatically; an expiry banner appears before you lose
  access rather than after. The server list is cached offline and refreshed when the
  profile changes, so a dead network doesn't leave you staring at an empty picker.
- **Updates without a store.** The app checks an appcast, and on Android installs the APK
  in place. Updates are fetched **through the proxy tunnel** — the one moment you most
  need an update is when the plain connection is already blocked.
- **Opens in Russian, with no first-run tour.** Language and region default to `ru`, and
  the intro screens are gone: the first screen is the connect button.

Everything else — the sing-box core, the protocol support, the routing engine — is
Hiddify's, and the credit for it is Hiddify's too.

---

## Table of contents

- [Installation](#installation)
- [Tech stack](#tech-stack)
- [Build](#build)
- [Required secrets](#required-secrets)
- [Where the AxiOm-specific code lives](#where-the-axiom-specific-code-lives)
- [Relationship to Hiddify](#relationship-to-hiddify)
- [License](#license)

---

## Installation

Builds are published on the [releases page](https://github.com/AxiOm-Labs-Inc/AxiOm-v2/releases/latest).

| Platform | File | Notes |
|---|---|---|
| Android | `AxiOm-v<version>-arm64.apk` | arm64 devices; the app updates itself afterwards |
| Windows | `AxiOm-Windows-v<version>.zip` | unpack and run; published less often than Android |

There is no App Store or Google Play build, and none is planned — see
[Relationship to Hiddify](#relationship-to-hiddify).

A subscription link is needed to connect. Getting one is described on
[axiom.arcohouse.space](https://axiom.arcohouse.space/).

---

## Tech stack

- **Flutter** (Dart 3) — Android and Windows from one codebase
- **[sing-box](https://github.com/SagerNet/sing-box)** via `hiddify-core` — the tunnel itself
- **Riverpod** + `flutter_hooks` — state
- **drift** / **shared_preferences** — local storage
- 11 interface locales inherited from upstream; Russian is the default

---

## Build

A standard Flutter project on top of Hiddify. The native core is **not** vendored here:
fetch it with the upstream Makefile targets first (see the
[Hiddify build docs](https://github.com/hiddify/hiddify-app)), then:

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter build apk --release          # Android
flutter build windows --release      # Windows
```

Without the native core, `pub get`, code generation and `flutter analyze` still work —
only linking a binary does not.

### Required secrets

Deliberately kept out of the repository:

1. **Signing keystore** — `android/key.properties` + `android/app/release.jks`
   (git-ignored). Bring your own for release builds.

2. **Device-service API key** — the device counter calls a backend API. Pass it at build
   time rather than committing it:

   ```bash
   flutter build apk --release --dart-define=DEVICE_API_KEY=<your_key>
   flutter build windows --release --dart-define=DEVICE_API_KEY=<your_key>
   ```

   Without it the device counter simply stays hidden; everything else works.

---

## Where the AxiOm-specific code lives

Most of the tree is upstream Hiddify. The parts written for AxiOm:

| Path | What it is |
|---|---|
| `lib/features/home/widget/server_selector_card.dart` | the country → protocol → transport cascade |
| `lib/features/proxy/model/server_option.dart` | the model the raw outbound list is folded into |
| `lib/features/proxy/data/server_list_cache.dart` | offline cache of the server list |
| `lib/features/home/data/device_count_provider.dart` | live device counter for the subscription |
| `lib/features/stats/widget/connection_stats_card.dart` | traffic / days / ping / devices row |
| `lib/features/account/` | Telegram login, subscriptions, expiry banner |
| `lib/features/app_update/` | appcast check and in-app APK install |
| `lib/features/telemost/` | Telemost tab |
| `assets/images/logo.svg`, `android/app/src/main/res/` | AxiOm branding (Ω) |

---

## Relationship to Hiddify

AxiOm is a customized build of [Hiddify](https://github.com/hiddify/hiddify-app), which
in turn wraps the [sing-box](https://github.com/SagerNet/sing-box) core. The tunnel, the
protocol implementations and the routing engine are theirs; AxiOm changes the interface
layer described above, adds subscription and update handling, and rebrands the app.

This repository is a standalone snapshot and does not carry the upstream git history.
The list of changes is kept in [What AxiOm changes](#what-axiom-changes) above, and
per-release notes are on the
[releases page](https://github.com/AxiOm-Labs-Inc/AxiOm-v2/releases).
`CHANGELOG.md` in this tree is upstream Hiddify's and stops at their 0.16.0.

---

## License

Upstream **[Hiddify Extended GNU GPL v3](LICENSE.md)** — GPL v3 plus additional
conditions attached under GPL v3 Section 7. Read [`LICENSE.md`](LICENSE.md) in full
before reusing anything from this repository: the added conditions cover, among other
things, how a derivative must be published, how releases must be produced, attribution,
naming, and commercial use.

Credit for the underlying work belongs to
[Hiddify](https://github.com/hiddify/hiddify-app) and
[sing-box](https://github.com/SagerNet/sing-box).
