# Онбординг: клиент AxiOm

> Приватный документ: в публичный `AxiOm-v2` не переносить.
>
> Первое чтение для любого, кто открыл этот репозиторий — человека или агента.
> После него: [BUILD_AND_RELEASE.md](BUILD_AND_RELEASE.md) (сборка и релиз) и
> [PUBLISHING.md](PUBLISHING.md) (что можно в публичный репозиторий).

---

## 1. Что это

AxiOm — VPN-клиент для **Android** и **Windows**. Форк
[hiddify-app](https://github.com/hiddify/hiddify-app): Flutter-интерфейс поверх
ядра sing-box (hiddify-core).

Своё поверх апстрима:

- **Личный кабинет** — вход через Telegram, подписка, оплата внутри приложения.
- **Вкладка «Telemost»** — режим для белых списков: трафик идёт через
  видеоканал, когда обычный VPN заблокирован. Внутреннее название механики —
  **WBStream**. Название вкладки «Telemost» историческое, не переименовывать: на
  нём завязан флаг доступа `features.telemost` на сервере.
- **Свои идентификаторы** — пакет `app.axiom.vpn`, Dart-пакет `axiom`, свои порты
  и схема `axiom://`, чтобы не конфликтовать с настоящим Hiddify
  ([REBRANDING.md](REBRANDING.md) — прочитать до того, как трогать имена,
  User-Agent, каналы или иконки).

Серверная часть (бот, API кабинета, панель, держатели Телемоста) живёт в других
репозиториях и на серверах — менять её отсюда не нужно.

---

## 2. Репозитории

| Репозиторий | Что |
|---|---|
| `AxiOm-Labs-Inc/AxiOm-v2-dev` 🔒 | **этот.** Вся работа, все сборки |
| `AxiOm-Labs-Inc/AxiOm-v2` 🌍 | публичная витрина: Releases, `appcast.xml`. Код туда — только выборочно ([PUBLISHING.md](PUBLISHING.md)) |
| `AxiOm-Labs-Inc/AxiOm-relay-dev` 🔒 | исходник `librelay.so` (Go). Нужен только для пересборки relay |

Ветка `master` — основная. Для задачи заводите ветку, в `master` — после проверки.

---

## 3. Карта кода

```
lib/
  main.dart, main_prod.dart   точки входа: dev и боевая (релиз — только main_prod)
  bootstrap.dart              запуск: префы, миграции, ядро, проверка обновлений
  axiomcore/                  обёртка ядра sing-box (gRPC/FFI), статусы подключения
  singbox/                    модели конфига и опций ядра
  core/                       общее: роутер, тема, локализация, префы и их миграции, http, логгер
  features/
    home/                     главный экран, кнопка подключения, счётчик устройств
    connection/               состояние VPN-подключения
    profile/                  профили (подписки), их обновление
    account/                  личный кабинет: вход через Telegram, подписка, оплата
    wbstream_tunnel/          🔒 вкладка Telemost (приватная)
    app_update/               проверка и установка обновлений
    settings/, per_app_proxy/, route_rules/, log/, stats/, about/, intro/ …
  gen/                        сгенерированное (переводы, биндинги) — не править руками

android/app/src/main/kotlin/app/axiom/
  bg/BoxService.kt            сервис ядра (VPN)
  TunnelMethodHandler.kt      🔒 канал Flutter ↔ relay Телемоста
  TunnelRelayController.kt    🔒 запуск и статусы процесса librelay.so
android/app/src/main/jniLibs/ 🔒 librelay.so

windows/runner/               C++ раннер: права администратора, одна копия окна
windows/packaging/exe/        установщик Inno Setup (AxiOm.iss)
assets/translations/          строки интерфейса (*.i18n.json)
scripts/                      сборка, проверки, скачивание ядра
docs/                         документация (см. docs/README.md)
```

### Как устроен Телемост (в двух словах)

1. Вкладка (`wbstream_page.dart`) → `WbstreamTunnelNotifier` получает секрет
   аккаунта (`telemost_credentials_service.dart`: с сервера кабинета или из кода
   активации `AXT1-…`).
2. `TunnelMethodHandler` запускает `librelay.so` отдельным процессом. Relay сам
   находит комнату, поднимает видеоканал и отдаёт готовый фрагмент конфига.
3. То же ядро sing-box перезапускается с этим конфигом. Ядро одно на VPN и
   Телемост; кто им сейчас владеет — `core_owner.dart`.
4. Relay принадлежит процессу приложения, а не экрану: Телемост переживает
   сворачивание и закрытие из недавних, новый экран подхватывает работающий
   туннель (`_restoreRunning`). Остановка ядра из уведомления гасит и relay.

Доступ к Телемосту даёт сервер (тариф + активная подписка); держатели на
серверах проверяют секрет. Без действующей подписки relay не подключится.

**Код активации `AXT1-…`** — запасной путь для человека, у которого не открываются
ни сервер кабинета, ни Telegram: тот же секрет аккаунта, упакованный в строку
(вводится кнопкой «У меня есть код активации» на экране Телемоста). Выдаёт его
владелец серверным скриптом по Telegram ID; код личный, передаётся файлом, не
текстом в чат.

Устройство relay (поиск комнаты, авторизация, держатели) — `docs/ONBOARDING.md`
в `AxiOm-relay-dev`.

---

## 4. Первые шаги

1. Установить окружение и получить секреты — [BUILD_AND_RELEASE.md §2–3](BUILD_AND_RELEASE.md#2-подготовка-машины-один-раз).
2. `scripts/fetch_core.sh` и `scripts/build_android.sh` — если APK собрался и
   `verify_apk.py` зелёный, машина готова.
3. Поставить APK на телефон и пройти: подключение VPN, вход в кабинет, Телемост.

---

## 5. Как работать каждый день

```bash
git switch master && git pull          # всегда перед началом: в репозиторий пишут несколько человек и агентов
git switch -c <задача>
# ... правки ...
dart run build_runner build --delete-conflicting-outputs   # если трогали модели, провайдеры, переводы
flutter analyze lib/features lib/core                       # 0 ошибок
git commit                                                   # формат — docs/COMMIT_FORMAT.md
git push -u origin <задача>
```

- **Перед началом задачи** — `git pull` и `git log --oneline -20`: задача могла
  быть уже сделана кем-то параллельно.
- **Коммиты** — по-русски, заголовок `Область: что стало`, в теле — почему
  ([COMMIT_FORMAT.md](COMMIT_FORMAT.md)).
- **Проверка на устройстве** обязательна для всего, что касается подключения,
  Телемоста и жизненного цикла приложения — в эмуляторе это не воспроизводится.
- Логи Android: `adb logcat -v time | grep -iE "axiom|flutter|relay|BoxService"`.

---

## 6. Правила, которые нельзя нарушать

1. **Секреты — никогда в git**, даже в приватный: ключ подписи, пароли,
   `DEVICE_API_KEY`, токены, а также пути к файлам с ними. Они в `.gitignore` —
   проверяйте `git status` перед коммитом.
2. **В публичный репозиторий — только выборочно**, никогда merge;
   перед публикацией — `scripts/check_public_tree.sh` ([PUBLISHING.md](PUBLISHING.md)).
3. **Релиз — только скриптами и с `verify_apk.py`** ([BUILD_AND_RELEASE.md §9](BUILD_AND_RELEASE.md#9-релиз-шаг-за-шагом)).
4. **Подписывать только ключом AxiOm.** Другой ключ = пользователи не смогут
   обновиться.
5. **Не переименовывать то, что видит сервер:** User-Agent, вкладку Telemost,
   `features.telemost`, схему `axiom://` — без согласования с владельцем
   ([REBRANDING.md §3](REBRANDING.md)).
6. **`AppId` в `AxiOm.iss` и `applicationId` Android не менять никогда.**

---

## 7. Документы

| Документ | О чём |
|---|---|
| [BUILD_AND_RELEASE.md](BUILD_AND_RELEASE.md) | окружение, сборка Android/Windows, relay, ядро, релиз, грабли |
| [PUBLISHING.md](PUBLISHING.md) | публичный/приватный: что куда можно, как переносить |
| [RELEASE_NOTES_FORMAT.md](RELEASE_NOTES_FORMAT.md) | как писать описание релиза |
| [COMMIT_FORMAT.md](COMMIT_FORMAT.md) | как писать коммит |
| [REBRANDING.md](REBRANDING.md) | что переименовано от Hiddify и почему, связь с правилами панели |
| [windows-setup-update.md](windows-setup-update.md) | Windows: установщик, автообновление, права администратора |
| [in-app-payment.md](in-app-payment.md) | оплата и кабинет во вкладке «Профили» |
