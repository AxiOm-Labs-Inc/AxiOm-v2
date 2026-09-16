# Сборка и релиз AxiOm

> Приватный документ: в публичный `AxiOm-v2` не переносить (его ловит
> `scripts/check_public_tree.sh`).
>
> Цель документа: с одним этим репозиторием и тремя секретами от владельца
> собрать Android и Windows и выпустить релиз, не спрашивая никого. Если где-то
> пришлось спросить — допишите сюда ответ.

**Содержание**

1. [Что откуда берётся](#1-что-откуда-берётся)
2. [Подготовка машины (один раз)](#2-подготовка-машины-один-раз)
3. [Первый запуск клона (один раз)](#3-первый-запуск-клона-один-раз)
4. [Сборка Android](#4-сборка-android)
5. [Сборка Windows](#5-сборка-windows)
6. [librelay.so — движок Телемоста](#6-librelayso--движок-телемоста)
7. [Ядро sing-box](#7-ядро-sing-box)
8. [Разработка: запуск и отладка](#8-разработка-запуск-и-отладка)
9. [Релиз шаг за шагом](#9-релиз-шаг-за-шагом)
10. [Как приложение узнаёт об обновлении](#10-как-приложение-узнаёт-об-обновлении)
11. [Грабли, на которые уже наступали](#11-грабли-на-которые-уже-наступали)

---

## 1. Что откуда берётся

| Что | Где | В git? |
|---|---|---|
| Код приложения (Flutter + Kotlin + C++ Windows) | этот репозиторий | да |
| `librelay.so` (arm64-v8a, armeabi-v7a) — движок Телемоста | `android/app/src/main/jniLibs/`, происхождение — `android/app/relay.version` | **да**, готовыми бинарниками |
| Исходник `librelay.so` | приватный `AxiOm-Labs-Inc/AxiOm-relay-dev`, каталог `relay/` | отдельный репозиторий, нужен только для пересборки relay (§6) |
| Ядро sing-box (`hiddify-core.aar`, `hiddify-core.dll`, `libcronet.dll`) | официальный релиз hiddify-core, качает `scripts/fetch_core.sh` | нет (107 МБ, больше лимита GitHub) |
| Установщик Windows | `windows/packaging/exe/AxiOm.iss` | да |
| `*.g.dart`, `*.freezed.dart`, переводы | генерируются `build_runner` | нет |
| **Ключ подписи** `release.jks` + `key.properties` | у владельца, передаётся лично | **никогда** |
| **`DEVICE_API_KEY`** | у владельца, передаётся лично | **никогда** |

Секретов ровно два набора (ключ подписи с паролями и `DEVICE_API_KEY`). Всё
остальное есть в репозитории или скачивается скриптом.

---

## 2. Подготовка машины (один раз)

### Общее

| Инструмент | Версия | Зачем |
|---|---|---|
| Flutter | **3.41.7** stable (Dart 3.11.5) | сборка. Другая минорная версия может собрать иначе — держите эту |
| Git + Git Bash | любая свежая | скрипты `*.sh` (на Windows запускать из Git Bash) |
| Python | 3.8+ | `scripts/verify_apk.py` |
| GitHub CLI `gh` | любая | релизы (`gh auth login` под аккаунтом с доступом к обоим репозиториям) |

### Android

| Инструмент | Версия |
|---|---|
| Android Studio (или только SDK) | любая свежая |
| JDK | 17+ (подходит встроенный в Android Studio JBR 21: `C:/Program Files/Android/Android Studio/jbr`) |
| Android SDK Platform | 36 (`compileSdkVersion 36`, `targetSdkVersion 36`) |
| NDK | **28.2.13676358** (`ndkVersion` в `android/app/build.gradle`) |
| Build-tools | любые свежие (нужны `aapt2` и `apksigner` для проверки) |

Проверка: `flutter doctor` — пункт Android toolchain зелёный. Если SDK стоит не в
стандартном месте, задайте `ANDROID_HOME`.

### Windows (только если собираете Windows)

| Инструмент | Примечание |
|---|---|
| Visual Studio **Community** (2022 или 2026) | нагрузка «Разработка классических приложений на C++» + компонент **ATL C++**. Без ATL падает `flutter_secure_storage_windows` (`atlstr.h`). Если рядом стоят Build Tools без ATL, CMake выбирает их сам — скрипт это обходит: находит студию с ATL и входит в её окружение |
| NuGet CLI | `nuget.exe` в `PATH` или просто положить в `tools\nuget.exe` (скрипт подхватит). Скачать: https://dist.nuget.org/win-x86-commandline/latest/nuget.exe |
| Inno Setup 6 | `winget install JRSoftware.InnoSetup`. Скрипт ищет `ISCC.exe` в `%LOCALAPPDATA%\Programs\Inno Setup 6` и `Program Files (x86)`, иначе задайте `INNO_SETUP_PATH` |

Windows-сборку можно делать только на Windows.

---

## 3. Первый запуск клона (один раз)

```bash
git clone https://github.com/AxiOm-Labs-Inc/AxiOm-v2-dev.git axiom
cd axiom

# Публичный репозиторий — отдельным remote с говорящим именем, чтобы случайный
# push туда был невозможен по привычке (см. docs/PUBLISHING.md)
git remote add public https://github.com/AxiOm-Labs-Inc/AxiOm-v2.git
git config remote.public.pushurl "НЕ_ПУШИТЬ_СЮДА_КОД__см_docs/PUBLISHING.md"
```

> У владельца remotes названы иначе: `dev` — приватный, `origin` — публичный.
> В документах ниже приватный называется `origin`, публичный — `public`.

### Секреты

Получите от владельца три вещи и разложите:

```bash
cp .env.example .env                               # вписать DEVICE_API_KEY=...
cp android/key.properties.example android/key.properties   # вписать пароли
# release.jks положить в android/app/release.jks
```

Все три пути в `.gitignore`. Проверить, что ничего не попадёт в коммит:

```bash
git status --short     # .env, key.properties, release.jks не должны появиться
```

### Ядро

```bash
scripts/fetch_core.sh android     # или: windows / all (по умолчанию all)
```

---

## 4. Сборка Android

```bash
scripts/build_android.sh              # полная сборка
scripts/build_android.sh --skip-gen   # если не меняли модели/переводы — быстрее
```

Что делает скрипт, по порядку:

1. **Проверяет, что всё на месте**, и останавливается, если нет:
   `.env` с ключом, `key.properties` и сам ключ, ядро, оба `librelay.so` и что
   relay свежий (есть маркер `gatedStatus`).
2. `flutter pub get` и `dart run build_runner build --delete-conflicting-outputs`
   (freezed, riverpod, drift, переводы slang — сгенерированных файлов в git нет).
3. `flutter build apk --release --split-per-abi -t lib/main_prod.dart --dart-define=DEVICE_API_KEY=…`
4. Копирует arm64 в `dist/AxiOm-v<версия>-arm64.apk`.
5. Запускает `scripts/verify_apk.py`.

Результат:

| Файл | Кому |
|---|---|
| `dist/AxiOm-v<версия>-arm64.apk` | **раздаём этот** — все современные телефоны |
| `build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk` | старые 32-битные телефоны, по запросу |
| `build/app/outputs/flutter-apk/app-x86_64-release.apk` | эмуляторы. Телемоста в нём нет (relay не собирается под x86_64) |

### Проверка APK

`scripts/verify_apk.py [путь]` — **обязательна перед тем, как APK уходит людям**,
даже собранный не скриптом. Каждый пункт — след реально испорченного выпуска:

| Проверка | Что было без неё |
|---|---|
| версия = `pubspec.yaml` | APK с тем же `versionCode` не ставится поверх |
| подпись = эталон `63c8ce05…f942` | APK с чужой подписью не обновляет приложение — только удаление с потерей профилей |
| в `libapp.so` есть `main_prod` | до 04.09.2026 все сборки были dev: подробные логи у всех пользователей, падение вместо восстановления настроек |
| вкомпилирован `DEVICE_API_KEY` | 4.3.x ушла без ключа — счётчик устройств пропал молча, заметили через неделю |
| адрес лимитера `fr.arcohouse.space/devices` | ловит откат на старый мёртвый адрес |
| в Dart-коде нет адресов WB/Диска | они должны жить только в `librelay.so` |
| `librelay.so` с `gatedStatus` | 4.4.1–4.4.3 вышли со старым relay — Телемост не работал ни у кого |

Установить на подключённый телефон:

```bash
adb install -r dist/AxiOm-v<версия>-arm64.apk
```

---

## 5. Сборка Windows

Из PowerShell в корне репозитория:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1
powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1 -SkipGen
```

Скрипт проверяет `.env`, ядро в `hiddify-core\bin`, NuGet, Visual Studio с ATL
и Inno Setup, входит в окружение этой студии (если прошлая сборка была другой
студией — сбрасывает кэш CMake), затем:

1. `flutter pub get`, `build_runner`.
2. `flutter build windows --release -t lib/main_prod.dart --dart-define=DEVICE_API_KEY=…`
3. Проверяет результат: `axiom-core.dll` на месте, в `data\app.so` есть
   `main_prod`, ключ и адрес лимитера.
4. Собирает установщик: `ISCC /DAppVersion=<версия> windows\packaging\exe\AxiOm.iss`.

Результат: **`dist\AxiOm-v<версия>-Setup.exe`**.

Как устроено:

- Ядро в сборке переименовывается в `axiom-core.dll` (`windows/CMakeLists.txt`).
  `libcronet.dll` не переименовывать: ядро загружает её по этому имени.
- `AxiOm.iss` один на все версии. **`AppId` в нём не менять никогда**: по нему
  установщик находит установленный AxiOm и обновляет его, а не ставит вторую копию.
- Установщик убивает только `AxiOm.exe` и удаляет только `{userappdata}\AxiOm`.
  Не трогать `hiddify.exe` и `{userappdata}\Hiddify`: это чужое приложение,
  которое может стоять на той же машине.
- Старые `AxiOm-v4.4.x.iss` … `AxiOm-v4.5.1.iss` — история, для сборки не нужны.
- Права администратора, режим VPN, тихое обновление — `docs/windows-setup-update.md`.

Проверить установщик руками: поставить поверх предыдущей версии → приложение
запускается, профили на месте, в «О программе» новая версия.

---

## 6. librelay.so — движок Телемоста

Нативный Go-бинарник: сам находит комнату, держит видеоканал и отдаёт ядру
готовый конфиг. Приложение запускает его отдельным процессом
(`TunnelRelayController.kt`) и общается через `TunnelMethodHandler.kt`.

**Готовые `.so` лежат в репозитории** — для обычной сборки ничего делать не
нужно. Из какого коммита relay они собраны, записано в
`android/app/relay.version`.

### Когда пересобирать

Только когда в `AxiOm-relay-dev` изменился `relay/`. Изменения relay почти
всегда парные с серверами (NL/FR, RU) — их делает владелец или по согласованию
с ним.

### Как пересобрать

Нужен Go **1.26.1** (`relay/go.mod`) и доступ к `AxiOm-Labs-Inc/AxiOm-relay-dev`.

```bash
git clone https://github.com/AxiOm-Labs-Inc/AxiOm-relay-dev.git
cd AxiOm-relay-dev/relay
APP=/путь/к/этому/репозиторию

CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -trimpath -ldflags="-s -w" \
  -o "$APP/android/app/src/main/jniLibs/arm64-v8a/librelay.so" .

CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 \
  go build -trimpath -ldflags="-s -w" \
  -o "$APP/android/app/src/main/jniLibs/armeabi-v7a/librelay.so" .
```

Затем в этом репозитории:

1. Обновить `android/app/relay.version`: `commit` (`git rev-parse HEAD` в
   relay), `built` (дата), `sha256.*` (`sha256sum android/app/src/main/jniLibs/*/librelay.so`).
2. Проверить маркер: `grep -ac gatedStatus android/app/src/main/jniLibs/*/librelay.so` — не 0.
3. Собрать APK, проверить Телемост на телефоне (подключение, открываются сайты).
4. Закоммитить `.so` и `relay.version` одним коммитом:
   `Телемост: relay <коротко что изменилось> (<sha relay>)`.

### Что важно знать

- Строки механики внутри `.so` обфусцированы (XOR) — это сокрытие от `strings`,
  не защита. Настоящая защита — авторизация на серверах.
- Ключ слота вшит в relay и **парный серверному**. Менять его можно только
  одновременно с серверами — это делает владелец.
- Старые клиенты с устаревшим relay перестают подключаться при смене серверной
  авторизации — поэтому версия relay в релизе важна.

---

## 7. Ядро sing-box

Используем **официальный релиз hiddify-core v4.1.0 без изменений**. Пересобрать
ядро с другой версией xray нельзя: xray-часть в публичном исходнике hiddify
заглушена.

- Скачать: `scripts/fetch_core.sh [android|windows|all]`. Скрипт сверяет
  SHA-256 архивов, поэтому подмену или битую загрузку не пропустит.
- Обновить версию ядра: в `scripts/fetch_core.sh` поменять `CORE_VERSION` и обе
  суммы. Суммы взять из релиза:
  `gh release view v<версия> -R hiddify/hiddify-next-core --json assets -q '.assets[]|select(.name|test("lib-(android|windows)"))|"\(.name) \(.digest)"'`.
  После смены ядра — полный прогон подключения на Android и Windows: API ядра
  между версиями меняется.
- `dependencies.properties` (`core.version`) и цели `make android-libs` /
  `make windows-libs` — старый путь от апстрима, скрипт его заменяет.

---

## 8. Разработка: запуск и отладка

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # после правки моделей/провайдеров/переводов
dart run build_runner watch --delete-conflicting-outputs   # или в фоне во время работы

flutter run -t lib/main.dart --dart-define=DEVICE_API_KEY=<ключ>    # dev-окружение, подробные логи
flutter analyze lib/features lib/core                                # 0 ошибок перед коммитом
```

- `lib/main.dart` — dev (подробные логи, падает на ошибках миграции — удобно
  ловить баги). `lib/main_prod.dart` — то, что получают пользователи.
- Переводы: `assets/translations/*.i18n.json` → генерируется `lib/gen/translations.g.dart`.
- Логи Android: `adb logcat -v time | grep -iE "axiom|flutter|relay|BoxService"`.
- Телемост в отладке работает только на реальном arm-телефоне (relay не
  собирается под x86_64 эмулятор).
- Подпись debug-сборки другая — установить её поверх релизной нельзя, сначала
  `adb uninstall app.axiom.vpn`.

Структура кода, ребрендинг и почему что-то осталось с именем Hiddify —
`docs/ONBOARDING.md` и `docs/REBRANDING.md`.

---

## 9. Релиз шаг за шагом

Релиз = собранные файлы в **GitHub Release публичного `AxiOm-v2`** +
запись в **`appcast.xml` публичного `AxiOm-v2`**. Код в публичный репозиторий
при этом переносить не обязательно (см. `docs/PUBLISHING.md`).

### 9.1 Подготовка

```bash
git fetch origin public
git switch master && git pull
```

1. **Нет ли работы, которая лежит только в публичном репозитории.** Релиз
   собирается из приватного дерева — всё, что есть только в публичном, в релиз
   молча не попадёт (так 4.5.0 вышел без двух правок оплаты):
   ```bash
   git log --oneline --cherry-pick --right-only origin/master...public/master
   ```
   В выводе — коммиты публичного, которых нет в приватном. Каждый проверить:
   перенесён ли он другим коммитом (поиск по заголовку:
   `git log origin/master --oneline --grep="<слова из заголовка>"`). Не
   перенесённые — `git cherry-pick -x <sha>` и разрешить конфликты (в приватном
   импорты `package:axiom`, в публичном могут быть `package:hiddify`).
2. **Поднять версию** в `pubspec.yaml`:
   `version: X.Y.Z+NNNNN`, где `NNNNN = X*10000 + Y*100 + Z` (4.5.1 → `40501`).
   `versionCode` обязан расти, иначе Android не обновит приложение.
3. Коммит: `Версия X.Y.Z`.

### 9.2 Сборка и проверка

```bash
scripts/build_android.sh
```
```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1
```

**Руками на устройствах** (минимум перед каждым релизом):

| Проверка | Android | Windows |
|---|---|---|
| Обновление поверх прошлой версии, профили на месте | ✓ | ✓ |
| Подключение VPN, сайты открываются | ✓ | ✓ |
| Телемост: включение, сайты открываются, выключение | ✓ | — |
| Вход через Telegram, кабинет показывает подписку | ✓ | ✓ |
| Счётчик устройств на главной | ✓ | ✓ |
| То, что меняли в этом релизе | ✓ | ✓ |

### 9.3 Коммит и тег в приватном

```bash
git push origin master
git tag vX.Y.Z && git push origin vX.Y.Z
```

### 9.4 GitHub Release в публичном

Описание релиза — **только для пользователей**, по `docs/RELEASE_NOTES_FORMAT.md`
(никаких внутренних имён, серверов и устройства Телемоста). Эталон — описание
`v4.5.0`. Написать в файл `notes.md` (не в репозиторий).

```bash
gh release create vX.Y.Z -R AxiOm-Labs-Inc/AxiOm-v2 \
  --target master \
  --title "AxiOm X.Y.Z — <главное одной фразой>" \
  --notes-file notes.md \
  dist/AxiOm-vX.Y.Z-arm64.apk \
  dist/AxiOm-vX.Y.Z-Setup.exe
```

Имена файлов строго `AxiOm-vX.Y.Z-arm64.apk` и `AxiOm-vX.Y.Z-Setup.exe`:
приложение выбирает ассет по имени (для Windows ищет `*Setup*.exe`).

### 9.5 appcast.xml в публичном — без этого обновление никто не увидит

Отдельный клон публичного репозитория (не смешивать с приватным деревом):

```bash
git clone https://github.com/AxiOm-Labs-Inc/AxiOm-v2.git axiom-public
cd axiom-public
```

В `appcast.xml` добавить **первым** в группе своей платформы по элементу на
каждую выпущенную платформу — и только на неё:

```xml
<item>
    <title>Version X.Y.Z</title>
    <pubDate>Wed, 16 Sep 2026 12:00:00 +0000</pubDate>
    <enclosure
        url="https://github.com/AxiOm-Labs-Inc/AxiOm-v2/releases/download/vX.Y.Z/AxiOm-vX.Y.Z-arm64.apk"
        sparkle:version="X.Y.Z" sparkle:os="android" />
</item>
```

Для Windows — такой же элемент с `AxiOm-vX.Y.Z-Setup.exe` и `sparkle:os="windows"`
(первым среди windows-элементов).

```bash
git commit -am "appcast: X.Y.Z (Android + Windows)"
git push
```

Тот же `appcast.xml` скопировать в приватный репозиторий и закоммитить —
чтобы файлы не расходились.

### 9.6 Проверка после публикации

```bash
gh release view vX.Y.Z -R AxiOm-Labs-Inc/AxiOm-v2 --json assets -q '.assets[]|"\(.name) \(.state)"'   # uploaded
curl -sIL https://github.com/AxiOm-Labs-Inc/AxiOm-v2/releases/download/vX.Y.Z/AxiOm-vX.Y.Z-arm64.apk | grep -i '^HTTP'   # 200
curl -s https://raw.githubusercontent.com/AxiOm-Labs-Inc/AxiOm-v2/master/appcast.xml | grep -m2 'X.Y.Z'
```

Raw-файл GitHub кэширует до ~5 минут. Потом открыть старую версию приложения —
на главной должна появиться плашка обновления.

### 9.7 Если релиз оказался сломанным

- Не удалять релиз, пока не готова замена: у части людей скачивание уже идёт.
- Быстро: откатить `appcast.xml` на предыдущую версию — новые люди перестанут
  получать плашку.
- Правильно: выпустить X.Y.(Z+1) с исправлением. Понизить версию у тех, кто уже
  обновился, Android не даст.

---

## 10. Как приложение узнаёт об обновлении

1. При старте `AppUpdateNotifier.check()` запрашивает GitHub Releases API
   публичного репозитория, пакет `upgrader` читает `appcast.xml` оттуда же
   (`lib/core/model/constants.dart`).
2. Если есть новее — на главной неубираемая плашка → диалог → скачивание ассета
   из Release.
3. Android: системный установщик пакетов. Windows: `Setup.exe` запускается тихо
   (`/VERYSILENT … /RESTARTAPPLICATIONS`), закрывает приложение, ставит и
   запускает новую версию.

Release без `appcast.xml` = плашки нет. `appcast.xml` без ассета с точным
именем = плашка есть, скачивание падает.

---

## 11. Грабли, на которые уже наступали

| Что случилось | Как не повторить |
|---|---|
| Сборки до 04.09.2026 были dev — забывали `-t lib/main_prod.dart` | собирать скриптом; `verify_apk.py` |
| 4.3.x без `DEVICE_API_KEY` — счётчик устройств молча пропал | скрипт не соберёт без `.env`; `verify_apk.py` |
| 4.4.1–4.4.3 со старым `librelay.so` — Телемост не работал вообще | проверка `gatedStatus`; `relay.version` |
| 4.5.0 без правок, сделанных в публичном репозитории | шаг 9.1 |
| 04.09 merge приватной ветки выложил механику Телемоста в публичный | `docs/PUBLISHING.md`, `scripts/check_public_tree.sh` |
| Раздутое техническое описание `v4.4.0` пришлось срочно чистить | `docs/RELEASE_NOTES_FORMAT.md` |
| До 4.5.0 AxiOm делил с настоящим Hiddify имена, порты и схему ссылок — установка одного мешала другому | не возвращать имена апстрима в `AxiOm.iss` и коде (`docs/REBRANDING.md`) |
| Windows-сборка падала на `atlstr.h`: CMake взял Build Tools без ATL, хотя рядом стоит Community с ATL | `build_windows.ps1` сам выбирает студию с ATL |
| `flutter clean` без нужды — долгая полная пересборка | при смене иконки Windows достаточно удалить `build\windows\x64\CMakeCache.txt` |
| Релиз собран, `appcast.xml` не обновлён — обновление никто не получил | шаг 9.5 обязателен |
