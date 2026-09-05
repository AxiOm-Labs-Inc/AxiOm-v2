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
