# Windows: Setup.exe и автообновление

С **4.4.0** Windows раздаётся как **Inno Setup** (`AxiOm-vX.Y.Z-Setup.exe`): один файл для пользователя, установка в `Program Files\AxiOm`, обновление из приложения без ручной распаковки zip.

## Поток в рантайме

1. `AppUpdateNotifier.check()` → GitHub Releases API → `GithubReleaseParser`.
2. Для Windows выбирается ассет: `*Setup*.exe` → любой `.exe` → `.zip` (fallback).
3. Плашка на главной → `NewVersionDialog` → `UpdateDownloader.downloadUpdate`.
4. `installUpdate`:
   - `.exe` — запуск с флагами Inno `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS` (detached), затем `exit(0)`;
   - `.zip` — открыть папку в Explorer (старый portable-путь).
5. Inno закрывает `AxiOm.exe`, копирует файлы, секция `[Run]` без `skipifsilent` поднимает новую версию.

Плашка версии также завязана на `appcast.xml` (`sparkle:os="windows"`). URL в appcast и имя ассета в Release должны совпадать.

## Файлы

- `lib/features/app_update/data/github_release_parser.dart`
- `lib/features/app_update/data/update_downloader.dart`
- `lib/core/router/dialog/widgets/new_version_dialog.dart`
- `windows/packaging/exe/make_config.yaml`
- `windows/packaging/exe/inno_setup.sas` — kill `AxiOm.exe`, не `hiddify.exe`; не ставить `skipifsilent` на postinstall Run

## Сборка релизного Setup

Требования: Flutter Windows desktop, **VS Community с ATL** (не только BuildTools), NuGet CLI, Inno Setup 6, `hiddify-core/bin`.

```powershell
# VsDevShell Community + PATH: nuget, ISCC, fastforge (опционально)
$env:INNO_SETUP_PATH = "$env:LOCALAPPDATA\Programs\Inno Setup 6"  # если ISCC не в Program Files (x86)

flutter build windows --release -t lib/main_prod.dart --dart-define=DEVICE_API_KEY=<ключ>

# Вариант A: fastforge
fastforge package --platform windows --targets exe --skip-clean `
  --build-target=lib/main_prod.dart --build-dart-define=DEVICE_API_KEY=<ключ>

# Вариант B: ISCC вручную по Release/
# Source = build\windows\x64\runner\Release\*
# OutputBaseFilename = AxiOm-vX.Y.Z-Setup
```

Имя ассета в релизе: **`AxiOm-vX.Y.Z-Setup.exe`**.

## Публикация

1. `gh release upload vX.Y.Z AxiOm-vX.Y.Z-Setup.exe -R AxiOm-Labs-Inc/AxiOm-v2`
2. В публичном `appcast.xml` — item Windows с этим URL; закоммитить в `master` публичного `AxiOm-v2`.
3. Без шага 2 плашка у клиентов не появится (см. DEVELOPMENT.md §6).

## Замечания

- На диске после установки всегда **папка** приложения; «один exe» = установщик/дистрибутив, не single-file portable.
- Первая установка / переход с zip — руками запустить Setup; дальше апдейты из приложения.
- Не светить в публичных release notes внутренности Telemost / relay / auth.

## Права администратора и режим службы (с 4.4.3)

Windows-клиент запускается **от администратора** и по умолчанию работает в режиме
службы **VPN (TUN)**.

Почему: системный прокси уважает только софт, который спрашивает настройки WinINET.
Часть браузеров ходит мимо (свои настройки прокси, DoH), приложения со своим сетевым
стеком — тем более. Симптом обманчивый: VPN «подключён», часть сайтов открывается, а
конкретный сервис нет. Разбор такого случая 10.09.2026 (Telegram Web не открывался ни
на одном сервере при полностью исправных транспортах — 20/20 отдавали 200 и WSS 101)
занял часы. TUN перехватывает трафик всех приложений и этого класса отказов не имеет.

Что для этого изменено:

| Файл | Изменение |
|------|-----------|
| `windows/runner/runner.exe.manifest` | `requestedExecutionLevel level="requireAdministrator"` |
| `lib/singbox/model/singbox_config_enum.dart` | `ServiceMode.defaultMode` → `tun` на Windows |
| `lib/core/preferences/preferences_migration.dart` | миграция prefs **v6**: `service-mode` `system-proxy` → `vpn`, только Windows |
| `lib/features/auto_start/notifier/auto_start_notifier.dart` | автозапуск на Windows — задача планировщика `AxiOmAutostart` |

Миграция v6 перебивает только `system-proxy` (значение прежнего дефолта). Режим
`proxy` — голый локальный порт, его выбирают осознанно — не трогается. Linux и macOS
остаются на системном прокси: сборок под них мы не выпускаем.

### Следствия, о которых надо помнить

- **UAC при каждом запуске.** Обойти это, оставаясь в одном процессе с ядром,
  нельзя: TUN-адаптер и правка таблицы маршрутов требуют elevation.
- **Автозапуск переехал в планировщик.** Windows не поднимает elevated-процессы ни
  из `HKCU\...\Run`, ни из папки «Автозагрузка» — молча пропускает. Поэтому вместо
  `launch_at_startup` создаётся задача `AxiOmAutostart` (`/sc onlogon /rl highest`).
  У кого автозапуск был включён до 4.4.3, того первый запуск переносит на задачу
  автоматически. Если задача не создалась (групповые политики, урезанный
  планировщик) — переключатель в UI честно возвращается в «выключено».
- **Пользователь без прав администратора приложение не запустит.** Для корпоративных
  машин с ограниченной учётной записью это регресс; запасной путь для них —
  переустановка на 4.4.2 или ручной режим `proxy` с прописыванием прокси в программу.
- **Обновление из приложения стало тише:** установщик, запущенный уже elevated
  процессом, наследует права и не показывает отдельный UAC.
- **Drag&drop из проводника в окно приложения перестаёт работать** — Windows не
  пропускает перетаскивание из неelevated Explorer в elevated-окно. Импорт профиля
  ссылкой, QR и из буфера не затронуты.

### Проверить после сборки

```powershell
schtasks /query /tn AxiOmAutostart        # после включения автозапуска в UI
```

1. Свежая установка → приложение стартует с запросом UAC, режим службы = VPN.
2. Обновление с 4.4.2, где стоял системный прокси → после первого запуска режим VPN.
3. Обновление с 4.4.2, где режим стоял `proxy` → остался `proxy`.
4. Включить автозапуск, перезагрузиться → приложение поднялось само.
