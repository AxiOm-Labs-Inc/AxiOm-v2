# Contributing

AxiOm is developed by the AxiOm team. Bug reports and questions go to the
[support bot](https://t.me/AxiOm_Npv_support_bot); issues in this repository use
the templates in `.github/ISSUE_TEMPLATE`.

## Development

The client is a Flutter app; the VPN core is a prebuilt binary downloaded by the
`Makefile` into `hiddify-core/bin` (the upstream core we build on).

```shell
make windows-prepare   # or: make android-prepare
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

Release packaging for Windows is described in `docs/windows-setup-update.md`.

## Attribution

AxiOm started as a fork of Hiddify (GPL-3.0). The license and the change history
of the original project are kept in `LICENSE.md` and `HISTORY.md`.
