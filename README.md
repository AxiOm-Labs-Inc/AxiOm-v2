# AxiOm

A multi-platform VPN client (Flutter + sing-box core).

## Highlights / customizations

- **Simplified server picker** — choose a server by **country + transport** (WebSocket /
  Reality) instead of a raw outbound list, plus an **Auto (fastest)** mode. The last choice
  is remembered between sessions.
- **WARP indicator** — when Cloudflare WARP detour is enabled, the picker shows a
  "Дополнительное шифрование WARP" badge and still lists the underlying servers.
- **Connection stats bar** — traffic, days, ping and a live **device counter** for the
  active subscription (with manual refresh). Unlimited traffic/expiry render as `∞`.
- **Connection timer** that survives the app process being killed in the background.
- AxiOm branding (Ω) across app icon, splash and UI.

## Build

> **Team members:** start with [`docs/ONBOARDING.md`](docs/ONBOARDING.md) — build
> scripts, release steps and repository rules are described there.

Android and Windows are the supported targets. Fetch the sing-box core (official
hiddify-core release, checksums verified), then build the **prod** entry point:

```bash
scripts/fetch_core.sh            # android + windows core libs
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter build apk --release --split-per-abi -t lib/main_prod.dart --dart-define=DEVICE_API_KEY=<key>
flutter build windows --release -t lib/main_prod.dart --dart-define=DEVICE_API_KEY=<key>
```

`-t lib/main_prod.dart` is required: the default `lib/main.dart` starts the app in the
dev environment (verbose logging, no recovery from broken preferences).

### Required secrets (not in this repo)

Intentionally git-ignored / externalized:

1. **Signing keystore** — `android/key.properties` + `android/app/release.jks`
   (git-ignored, template: `android/key.properties.example`). Release builds must be
   signed with the project key, otherwise they won't install over the existing app.

2. **Device-service API key** — the device counter calls a backend API. The key is **not**
   stored in source; put it into `.env` (template: `.env.example`) or pass it at build
   time with `--dart-define=DEVICE_API_KEY=<key>`. Without it, the device counter simply
   stays hidden (everything else works).

## License

See [LICENSE.md](LICENSE.md)
