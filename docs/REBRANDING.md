# Ребрендинг: клиент без идентификаторов Hiddify

> Приватный документ (только `AxiOm-v2-dev`). В публичный `AxiOm-v2` не переносить:
> здесь описано, как панель выбирает формат подписки.
>
> Сделано 11.09.2026 в ветке `rebrand` (тег отката `pre-rebrand` = `36cd51c`), версия 4.5.0.
> Журнал системы — `AxiOm_Architecture/MARZNESHIN_STATE.md`, запись «11.09.2026 (2)».

## 1. Зачем

AxiOm — форк Hiddify, и идентификаторы апстрима достались дословно. Это уже ломало
вещи: общие localhost-порты и gRPC-порт (чужой Hiddify на том же устройстве видел наше
ядро и показывал «VPN включён»), установщик убивал чужой `hiddify.exe` и стирал его
данные, ссылки `hiddify://` на Windows перехватывались нами. Цель — чтобы в клиенте
всё было своим, кроме самого бинаря ядра.

Ядро (`hiddify-core`) **не форкалось**: бинарь скачивается из релизов апстрима
(`Makefile`, `CORE_URL`), его внутренние имена переименовать без своей сборки Go нельзя.

## 2. Карта переименований

| Что | Было | Стало | Где |
|---|---|---|---|
| Dart-пакет | `hiddify` | `axiom` | `pubspec.yaml`, все `import 'package:axiom/…'` |
| Обёртка ядра | `lib/hiddifycore/`, `HiddifyCoreService` | `lib/axiomcore/`, `AxiomCoreService`, `axiomCoreServiceProvider` | |
| FFI-биндинги | `HiddifyCoreNativeLibrary` | `AxiomCoreNativeLibrary`, `lib/gen/axiom_core_bindings.dart` | ffigen в `pubspec.yaml` |
| Android: пакет исходников | `com.hiddify.hiddify` | `app.axiom` | `kotlin/app/axiom`, `aidl/app/axiom`, `namespace` в `build.gradle` |
| Android: каналы | `com.hiddify.app/*` | `app.axiom/*` | Kotlin + Dart одновременно, см. §5 |
| Android: интенты | `com.hiddify.app.SERVICE*` | `app.axiom.SERVICE*` | `constant/Action.kt` |
| Сессия VPN, имя канала уведомлений | `hiddify`, `hiddify service` | `AxiOm` | `VPNService.kt`, `ServiceNotification.kt` |
| User-Agent | `HiddifyNext/…`, xray: `HiddifyNextX/…` | `AxiOm/…`, xray: `AxiOmX/…` | `app_info_entity.dart`, см. §3 |
| Файл ядра на десктопе | `hiddify-core.dll/.so` | `axiom-core.dll/.so` | `RENAME` в `windows/` и `linux/CMakeLists.txt`, загрузчик `core_interface_desktop.dart` |
| Портативный каталог | `hiddify_portable_data` | `axiom_portable_data` (старый переносится) | `directories_provider.dart` |
| Linux | `hiddify`, `app.hiddify.com` | `axiom`, `app.axiom` | `linux/`, упаковка deb/AppImage/rpm |
| MSIX | `execution_alias: hiddify` | `axiom`, только схема `axiom` | `windows/packaging/msix` |
| Картинки | «Hi» в трее, баннере TV, иконке Linux | наш Ω | §7 |

Ранее (до ветки, в `master`): локальные порты 12334–12337 → 23334–23337, clash API
16756 → 23756, gRPC UI↔ядро 17078/17079 → 23078/23079, автозапуск `Hiddify.HiddifyNext` →
`AxiOm.AxiOm`, регистрация на Windows только своей схемы `axiom://`.

## 3. User-Agent и панель — трогать только в таком порядке

По User-Agent панель выбирает формат подписки. От формата зависит, получит ли
пользователь ShadowTLS и Naive: они есть только в sing-box JSON, а в base64-ссылках их нет.

Правила в панели (`settings.subscription.rules`, первое совпадение побеждает):

```
^AxiOmX       → base64-links   # xray-режим нашего клиента: в xray нет Naive
^AxiOm/       → sing-box       # наш клиент с 4.5.0
^[Hh]iddify[Nn]ext[Xx] → base64-links    ┐
…                                          │ 11 прежних правил — НЕ ТРОГАТЬ никогда:
^(SFA|…|[Hh]iddify[Nn]ext) → sing-box     │ их шлют установленные копии ≤4.4.4,
…                                          │ старые сборки (Dart/…) и сторонние клиенты
^Dart/        → sing-box                   │
.*            → base64-links              ┘
```

Правила:

- `^AxiOmX` стоит **раньше** `^AxiOm/`, иначе он бы не сработал (порядок важен при любой правке).
- Сменить имя продукта в UA (`kUserAgentProduct` в
  `lib/core/model/app_info_entity.dart`) можно только **после** того, как в панель
  добавлено правило под новое имя. Иначе новые клиенты получат base64 без ShadowTLS/Naive.
- xray-вариант UA строит `xrayUserAgent()` там же — не собирать его заменой строки.
- Хвост `like ClashMeta v2ray sing-box` оставлен: по нему формат выбирают чужие панели,
  куда пользователь может вставить ссылку.
- Проверка: подписка служебного пользователя с каждым UA до и после правки — формат,
  число конфигов и набор тегов должны совпасть; `AxiOm/…` ≡ `HiddifyNext/…`,
  `AxiOmX/…` ≡ `HiddifyNextX/…`.

## 4. Что сознательно осталось от апстрима

Это не долг, а граница. Если поиск `hiddify` находит что-то из списка — так и надо.

| Что | Почему остаётся |
|---|---|
| бинарь ядра: `hiddify-core/bin`, `libhiddify-core.so` в `.aar`, `HiddifyCore.xcframework`, `CORE_URL`, submodule в `.gitmodules`, проверка релиза в `.github/change_version.sh` | чужой бинарь, без форка ядра не переименовать |
| `com.hiddify.core.libbox`, `com.hiddify.core.api.*` в Kotlin | классы из бинаря ядра |
| протокол ядра: `.proto` в `android/app/src/main/protos/**`, `hiddifyoptions`, `ChangeHiddifySettings`, 50 файлов `lib/axiomcore/generated/**` | схема gRPC между UI и ядром; смена разорвёт связь |
| имена C-функций в `lib/gen/axiom_core_bindings.dart` | экспорт бинаря ядра |
| `libcronet.dll` | ядро грузит её по этому имени |
| `applicationId "app.axiom.vpn"` | смена = другое приложение, обновление поверх невозможно |
| ID канала уведомлений `"service"` | смена сбросит настройки уведомлений у пользователей |
| схемы `hiddify`, `clash`, `sing-box`, `v2ray*` в Android intent-filter и их разбор в `link_parsers.dart` | решение владельца: ссылки из других сервисов импортируются к нам. На десктопе регистрируется только `axiom` (`LinkParser.ownProtocols`) |
| `Hiddify.HiddifyNext` в `auto_start_notifier.dart` | чистка старой записи автозапуска (только если она указывает на наш exe) |
| `"hiddify-core", "hiddify-core.$ext"` в загрузчике под `FLUTTER_TEST` | путь к бинарю апстрима в тестах |
| `LICENSE.md`, `HISTORY.md`, `CHANGELOG.md`, атрибуция в `CONTRIBUTING.md`, `docs/ONBOARDING.md` | лицензия GPL-3.0 и история |
| `assets/fonts/emoji_source.txt` | происхождение файла шрифта |
| пути `D:\Creativ\AxiOm_APP_v2\hiddify-app\…` в `.iss` | реальное имя рабочего каталога владельца |
| `AxiOm-v4.4.0/4.4.2/4.4.3.iss` с `taskkill hiddify.exe` и удалением `{userappdata}\Hiddify` | архив выпущенных версий. **По ним не собирать**: убивают и стирают настоящий Hiddify. Актуальные — `AxiOm-v4.5.0.iss` и шаблон `inno_setup.sas` |
| комментарии, объясняющие развод с апстримом (порты, автозапуск, установщик) | документация решений |

## 5. Каналы Flutter ↔ Android

Имена каналов — строки, компилятор их не сверяет. Правило: **каждый канал, который
слушает Dart, должен быть зарегистрирован в Kotlin**, и менять имена только в одном
коммите на обеих сторонах.

| Канал | Kotlin | Dart |
|---|---|---|
| `app.axiom/method`, `/service.status`, `/service.alerts` | `MethodHandler`, `EventHandler` | `core_interface_mobile.dart` (`channelPrefix`) |
| `app.axiom/platform` | `PlatformSettingsHandler` | `directories_provider.dart`, `battery_optimization_repository.dart` |
| `app.axiom/tunnel`, `/tunnel.status` | `TunnelMethodHandler` | `wbstream_relay_service.dart` |
| `app.axiom/service.logs` | `LogHandler` | не слушается (логи идут через gRPC ядра; так и было до переименования) |

## 6. Выключенные функции апстрима

Три функции ходили на GitHub Hiddify. URL вынесены в `lib/core/model/constants.dart` и
равны `null` — функции выключены вместе с кнопками. Появится своё зеркало — вписать URL,
код включится сам.

| Константа | Что было |
|---|---|
| `autoAppsSelectionBaseUrl` | списки приложений для автоподбора раздельного туннеля (под Иран/Китай) |
| `autoAppsSelectionIssuesUrl` | кнопка «поделиться выбором» — issue в чужой репозиторий |
| `freeProfilesUrl` | бесплатные тестовые конфиги на чужих серверах (и переключатель «Бесплатно») |

Зависимость `circle_flags` берётся из форка `AxiOm-Labs-Inc/flutter_circle_flags` на том же
коммите, что был у апстрима.

## 7. Картинки

| Картинка | Файлы | Источник |
|---|---|---|
| иконка приложения Windows | `windows/runner/resources/app_icon.ico` | **эталон** нашего знака (кадры 16–256, PNG) |
| лаунчер Android | `android/app/src/main/res/mipmap-*/ic_launcher*.webp` | наш знак |
| иконка уведомлений | `res/drawable-*dpi/ic_stat_logo.png` | наш знак |
| трей, 4 состояния | `assets/images/tray_icon{,_dark,_connected,_disconnected}.{ico,png}` | из эталона: обычный и тёмный — как есть, «подключено» — Ω зелёный, «отключено» — серый |
| баннер Android TV | `res/mipmap-xhdpi/ic_banner.png` | из эталона: знак на тёмном фоне, без надписи |
| иконка Linux-пакетов | `assets/images/source/ic_launcher_border.png` | кадр 256 эталона |

Трей, баннер и иконку Linux пересобирает `scripts/make_brand_icons.py` из эталона —
без сторонних библиотек. Поменяли `app_icon.ico` — запустите скрипт из корня
репозитория и закоммитьте результат. Иконки лаунчера, уведомлений и сплэш он не трогает.

## 8. Что увидят пользователи при обновлении до 4.5.0

- Android: плитку в шторке нужно добавить заново (система хранит полное имя класса),
  ярлык на рабочем столе у части лаунчеров пропадёт. Always-on VPN хранится по
  `applicationId` — должен сохраниться (проверить на сборке). Профили, подписки,
  настройки не теряются (`FlutterSharedPreferences` привязан к `applicationId`).
- Windows: установщик 4.5.0 удаляет старые `hiddify-core.dll` и `HiddifyCli.exe` из папки
  программы (`[InstallDelete]`); портативная версия переносит `hiddify_portable_data`.
- Это нужно написать в заметках к релизу и в FAQ бота поддержки.

## 9. Как проверить, что ничего не вернулось

Из корня репозитория:

```bash
grep -rn 'package:hiddify' lib test                         # 0
grep -rnE 'com\.hiddify\.(hiddify|app)\b' lib android       # 0
find android/app/src -path '*com/hiddify*'                  # пусто
grep -rnIi hiddify lib android windows linux scripts pubspec.yaml Makefile \
  | grep -viE 'generated/|hiddifyoptions|ChangeHiddifySettings|com\.hiddify\.core\.|/protos/|scheme="hiddify"|hiddify-core|Hiddify\.HiddifyNext|legacyName|hiddify_portable_data|HiddifyCore\.xcframework|CORE_|LIB_NAME|BINDIR'
# остаток — комментарии о разводе с апстримом, 'hiddify' в link_parsers.dart
# (приём чужих ссылок), пути D:\…\hiddify-app и архивные .iss из §4
```

Сборка (у владельца): `flutter clean`, `flutter pub get`,
`dart run build_runner build --delete-conflicting-outputs`, `dart fix --apply` (порядок
импортов), `flutter analyze`, `flutter test`. Проверка на устройстве — чеклист в журнале
(запись «11.09.2026 (2)»).

## 10. Если нужно добавить что-то новое

- Новые идентификаторы — только с префиксом `app.axiom` / `axiom` / `AxiOm`, без `vpn`
  (исключение одно — унаследованный `applicationId`).
- Не брать дефолты из апстрима дословно: порты, имена пакетов, каналов, схем, записей
  автозапуска и каталогов данных у двух приложений на одном устройстве не должны совпадать.
- Не удалять и не убивать ничего с именем `hiddify` на машине пользователя — это может
  быть настоящий Hiddify.
