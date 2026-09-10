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

Windows-клиент по умолчанию работает в режиме службы **VPN (TUN)** и при старте
**сам запрашивает права администратора** — но отказ в UAC не мешает ему запуститься.

Почему вообще TUN: системный прокси уважает только софт, который спрашивает настройки
WinINET. Часть браузеров ходит мимо (свои настройки прокси, DoH), приложения со своим
сетевым стеком — тем более. Симптом обманчивый: VPN «подключён», часть сайтов
открывается, а конкретный сервис нет. Разбор такого случая 10.09.2026 (Telegram Web не
открывался ни на одном сервере при полностью исправных транспортах — 20/20 отдавали 200
и WSS 101) занял часы. TUN перехватывает трафик всех приложений и этого класса отказов
не имеет.

Почему повышение в рантайме, а не `requireAdministrator` в манифесте: с манифестным
требованием нажатие «Нет» в UAC означает, что приложение не запускается **вообще** —
пользователь остаётся без окна и без объяснения. Поэтому манифест оставлен `asInvoker`,
а права просит сам процесс.

### Как это работает

1. `main.cpp` при старте проверяет токен процесса (`IsProcessElevated`).
2. Прав нет → `RelaunchElevated()` перезапускает себя через `ShellExecuteExW` с
   `runas`; новая копия получает `--no-elevate`, чтобы не открывать UAC по кругу.
3. Успех → текущий процесс молча выходит, работу продолжает elevated-копия.
4. Отказ («Нет» в UAC) или повышение невозможно → процесс **продолжает работу**, а в
   аргументы Dart добавляется `--no-admin`.
5. Dart читает флаг в `WindowsAdmin.init(args)` из `main()`.

Проверка чужого окна (`SendAppLinkToInstance`) стоит **выше** повышения: второй клик по
ярлыку при уже запущенном приложении не должен приводить к лишнему запросу UAC.

### Что происходит в режиме без прав

| Что | Поведение |
|---|---|
| Режим службы | подменяется на системный прокси (`config_option_repository.dart`); сохранённая настройка не меняется и вернётся в силу после перезапуска с правами |
| Главный экран | плашка «Режим VPN недоступен» с кнопкой перезапуска (`windows_admin_banner.dart`), скрыть её нельзя |
| Перезапуск с правами | `WindowsAdmin.relaunchAsAdmin()` — detached powershell ждёт 1.5 с, пока текущая копия закроется (иначе новая увидит живое окно и выйдет), затем `Start-Process -Verb RunAs` |

### Файлы

| Файл | Изменение |
|------|-----------|
| `windows/runner/runner.exe.manifest` | явный `asInvoker` + объяснение, почему не `requireAdministrator` |
| `windows/runner/main.cpp` | `IsProcessElevated`, `RelaunchElevated`, флаг `--no-admin`, `ChangeWindowMessageFilterEx` |
| `lib/core/model/windows_admin.dart` | флаг ограниченного режима и перезапуск с правами |
| `lib/main.dart`, `lib/main_prod.dart` | `main(List<String> args)` → `WindowsAdmin.init(args)` |
| `lib/singbox/model/singbox_config_enum.dart` | `ServiceMode.defaultMode` → `tun` на Windows |
| `lib/core/preferences/preferences_migration.dart` | миграция prefs **v6**: `service-mode` `system-proxy` → `vpn`, только Windows |
| `lib/features/settings/data/config_option_repository.dart` | подмена режима на системный прокси, пока прав нет |
| `lib/features/home/widget/windows_admin_banner.dart` | плашка + подтверждение перезапуска |
| `lib/features/auto_start/notifier/auto_start_notifier.dart` | автозапуск задачей планировщика, с откатом на реестр |

Миграция v6 перебивает только `system-proxy` (значение прежнего дефолта). Режим `proxy`
— голый локальный порт, его выбирают осознанно — не трогается. Linux и macOS остаются на
системном прокси: сборок под них мы не выпускаем.

### Следствия, о которых надо помнить

- **UAC при каждом запуске** — пока пользователь работает в режиме VPN. Обойти это,
  оставаясь в одном процессе с ядром, нельзя.
- **Автозапуск живёт в двух местах.** Windows не поднимает elevated-процессы ни из
  `HKCU\...\Run`, ни из папки «Автозагрузка», поэтому основной путь — задача
  `AxiOmAutostart` (`/sc onlogon /rl highest`). Если создать её не удалось (нет прав,
  групповые политики), включение автозапуска откатывается на запись в реестре — она
  работает ровно в том случае, когда приложение и так стартует без повышения.
  Включённым считается любой из двух вариантов, выключение снимает оба.
- **Пользователь без прав администратора приложением пользуется.** Не как раньше
  задумывалось: он получает системный прокси и честную плашку, а не отказ в запуске.
- **Обновление из приложения:** установщик, запущенный elevated-копией, наследует права
  и не показывает отдельный UAC. В ограниченном режиме UAC на установку появится.
- **Deep-link `axiom://` в elevated-окно.** UIPI по умолчанию режет сообщения от
  неelevated процессов (браузер → наше окно), поэтому в `main.cpp` разрешён `WM_COPYDATA`
  через `ChangeWindowMessageFilterEx`. Если импорт по ссылке всё же не сработает —
  смотреть, каким сообщением пользуется `app_links`, и добавить его туда же.
- **Drag&drop из проводника в окно** в elevated-режиме не работает — ограничение
  Windows. Импорт ссылкой, QR и из буфера не затронуты.

### Проверить после сборки

```powershell
schtasks /query /tn AxiOmAutostart        # после включения автозапуска в UI
```

1. Свежая установка → UAC → «Да»: приложение стартует, режим службы = VPN, плашки нет.
2. Свежая установка → UAC → **«Нет»: приложение всё равно открывается**, висит плашка
   «Режим VPN недоступен», подключение работает системным прокси.
3. Кнопка в плашке → «Перезапустить» → UAC → «Да»: приложение поднялось с правами,
   плашка исчезла, режим VPN.
4. Обновление с 4.4.2, где стоял системный прокси → после первого запуска режим VPN.
5. Обновление с 4.4.2, где режим стоял `proxy` → остался `proxy`.
6. Включить автозапуск, перезагрузиться → приложение поднялось само.
7. Открыть ссылку подписки `axiom://` из браузера при запущенном elevated-приложении →
   профиль импортировался.
