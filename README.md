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

Standard Flutter project. Fetch the native sing-box core libs via the
Makefile targets, then:

```bash
flutter pub get
flutter build windows --release      # desktop
flutter build apk --release          # android
```

### Required secrets (not in this repo)

Intentionally git-ignored / externalized:

1. **Signing keystore** — `android/key.properties` + `android/app/release.jks`
   (git-ignored). Provide your own for release builds.

2. **Device-service API key** — the device counter calls a backend API. The key is **not**
   stored in source; pass it at build time:

   ```bash
   flutter build apk --release --dart-define=DEVICE_API_KEY=<your_key>
   flutter build windows --release --dart-define=DEVICE_API_KEY=<your_key>
   ```

   Without it, the device counter simply stays hidden (everything else works).

## License

See [LICENSE.md](LICENSE.md)
