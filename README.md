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

## CLI

The Windows Setup and Linux `.deb` automatically download the latest [SBX](https://github.com/Xenon-Tetraoxide/SBX-VPN-Client) release as `axiom` when installing or upgrading. On Windows, open a new terminal after installation. On Linux, the CLI requires `python3` and `sing-box`.

```text
axiom import <subscription-url>
axiom connect
axiom update
```

In the AxiOm CLI, `axiom update` updates the CLI itself; update subscriptions with `axiom sub update`. Uninstalling AxiOm also removes the CLI's autostart tasks.

The AxiOm CLI keeps its own data in `~/.config/axiom/cli` (Linux) / `%APPDATA%\AxiOm\cli` (Windows) and its own services/tasks (`axiom*`), so it does not interfere with a standalone SBX installation.

With AppImage, use `./AxiOm.AppImage cli <command>` instead; it downloads the CLI on first use. If the download fails, the desktop app is still available.

The app and the CLI share one VPN state and one selected server. Each app release also carries `AxiOm-cli-linux-amd64.tar.gz` and `AxiOm-cli-windows-amd64.zip` with the latest SBX, 1.4.0 or newer (`cli-assets.yml`, or manually `scripts/package_cli_assets.sh --upload <tag>`), so the old CLI (`cli-v0.0.x`) upgrades itself to SBX via `axiom update`; a manually unpacked old CLI is replaced by the app after an update.

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
