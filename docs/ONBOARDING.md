# Онбординг для агентов: клиентский репозиторий AxiOm (AxiOm-v2)

> Кому адресовано: любому агенту, который впервые открывает этот репозиторий.
> Это **первое чтение** на 5 минут — карта remotes/worktree, что можно пушить куда,
> как собрать, где секреты. Полные правила публикации и карта всех репозиториев
> системы — в приватном `AxiOm_Architecture` (`AGENTS_REPO_POLICY.md`), ссылки ниже.
>
> ⚠️ Если ты видишь этот файл — значит открыт **полный** (приватный) вариант дерева.
> В публичном `AxiOm-v2` его нет (см. §2).

---

## 1. Что это за проект

AxiOm — VPN-клиент, форк [hiddify/hiddify-app](https://github.com/hiddify/hiddify-app)
(Flutter + sing-box core), Android + Windows. Помимо стандартного VPN-функционала
в приложении есть вкладка **«AxiOm Telemost»** — это прикрытие для отдельной подсистемы
обхода whitelist-блокировок (внутреннее название **WBStream**). Название и иконку вкладки
не переименовывать — историческое, на нём завязан флаг доступа `features.telemost`.

Сопутствующий сервер-компонент (Go-релей `librelay.so`) живёт в отдельном
репозитории `AxiOm-relay-dev` — см. §2.

С 4.5.0 идентификаторы апстрима убраны (пакет `axiom`, Android `app.axiom`, UA `AxiOm/…`).
Что переименовано, что сознательно осталось от Hiddify и почему, как это связано с
правилами панели — [`docs/REBRANDING.md`](REBRANDING.md). Прочитать до того, как трогать
User-Agent, имена пакетов, каналов, схем или иконки.

---

## 2. Remotes, ветки, worktree — не перепутать публичный/приватный

**Два remote в одном клоне:**

```
origin → github.com/AxiOm-Labs-Inc/AxiOm-v2      (🌍 публичный, очищенное дерево)
dev    → github.com/AxiOm-Labs-Inc/AxiOm-v2-dev  (🔒 приватный, полное дерево)
```

**На диске несколько worktree одного и того же `.git`** (не отдельные клоны —
`git worktree`, конфиг веток у них общий):

| Каталог | Ветка | Назначение |
|---|---|---|
| `D:\Creativ\AxiOm_APP_v2\hiddify-app` | `master-private` | основной рабочий, полное дерево |
| `D:\Creativ\AxiOm_APP_v2\_tm-auth` | `master` | часто боевая сборка/релиз |
| `D:\Creativ\AxiOm_APP_v2\_fix-directdns` | `fix/pin-region-other` | незамерженный фикс (тумблер xray-ядра, регион `other`) |

**Guard от случайного публичного пуша** — бесаргументный `git push` НЕ уходит в
публичный `origin`:

| Ветка | Куда уходит `git push` без аргументов |
|---|---|
| `master` | в `dev` (`branch.master.pushRemote=dev`), `fetch`/`status` сверяются с `origin` |
| `master-private` | напрямую в `dev` (`branch.master-private.remote=dev`) |

Публикация в публичный репозиторий требует **явного** `git push origin <ветка>` —
осознанного действия. Полное объяснение механизма (почему конфиг общий на все
worktree, что делать при заведении новой ветки) — `AGENTS_REPO_POLICY.md` §3
в `AxiOm_Architecture`.

**Прежде чем пушить что-либо в `origin`** — прочитать `AGENTS_REPO_POLICY.md` §2.
Коротко: 🔴 `lib/features/wbstream_tunnel/**`, `TunnelMethodHandler.kt` /
`TunnelRelayController.kt`, `core_owner.dart`, `connect_lock_shield.dart` — только в
`dev`, никогда в `origin`. 🔴 `android/app/src/main/jniLibs/**` (сам `librelay.so`) —
никогда нигде в git, даже в `dev` (gitignored). 🟢 Остальное (оплата, UI, заглушка
`telemost_placeholder_page.dart`, флаг фичи) — можно в публичный, но **выборочным
переносом** файлов (`git checkout dev/master -- <путь>`), не мержем ветки — merge
затягивает запретные файлы целиком (инцидент 04.09.2026 разобран там же).

---

## 3. Сборка

```bash
flutter pub get
# нативные библиотеки sing-box подтягиваются Makefile-таргетами, ядро уже
# должно быть скачано в hiddify-core/bin — не гонять flutter clean без нужды
flutter build apk --release --dart-define=DEVICE_API_KEY=<ключ>
flutter build windows --release --dart-define=DEVICE_API_KEY=<ключ>
```

Без `--dart-define=DEVICE_API_KEY` сборка соберётся, но счётчик устройств в
приложении молча пропадёт (не упадёт, просто не покажет цифру) — известная готча,
проверялась на боевых релизах.

**`librelay.so` не в git — перед релизной сборкой пересобрать его из `main`
`AxiOm-relay-dev`** (`relay/`, `CGO_ENABLED=0 GOOS=linux GOARCH=arm64` и
`GOARCH=arm GOARM=7`, `-trimpath -ldflags="-s -w"`, вывод в `jniLibs/<abi>/`).
Устаревший бинарь молча ломает Телемост: 4.4.2 и 4.4.3 вышли с relay от 04.09 16:12 —
без ротации серверного WG-ключа и с ранним CONNECTED до CONFIG (в логе
`connected but no config received`). Проверка: `grep -ac gatedStatus
android/app/src/main/jniLibs/arm64-v8a/librelay.so` — не 0.

При смене иконки/сплэша — удалить `build\windows\x64\CMakeCache.txt`, не весь
`flutter clean` (полная пересборка ядра долгая и не нужна).

---

## 4. Секреты — не в этом репозитории, даже в приватном

Гитигнорено (проверить `git status`, что не попало в коммит):
- `android/key.properties`, `android/app/release.jks` — подпись релиза.
- `android/app/src/main/jniLibs/**` — сам `librelay.so`.
- Значение `DEVICE_API_KEY` — только в команде сборки/CI-переменной, не в коде.

Реальные значения (ключ, где взять/сгенерировать keystore) — в
`dev-docs/DEVELOPMENT.md` (сам каталог `dev-docs/` **вне git**, соседний с
worktree, не коммитить туда ничего репозиторием). Если такого каталога нет
локально — спросить владельца, не создавать секреты с нуля.

---

## 5. Куда писать отчёт о проделанной работе

**Не в этот репозиторий.** Как и для всех репозиториев системы AxiOm, отчёт о
сделанном (что изменилось, почему, где именно код) коммитится в приватный
журнал `AxiOm_Architecture` (`MARZNESHIN_STATE.md` или профильный `*.md`) —
см. `AGENTS_REPO_POLICY.md` §4 и его же `ONBOARDING.md` за общей картой системы
(серверы, SSH-доступ, остальные репозитории).

---

## 6. Первые пять минут в задаче — чеклист

1. `git status -sb` и `git remote -v` в **текущем** worktree — не путать, откуда
   ведётся работа (§2 выше).
2. Задача про WBStream/Telemost, ключи, подпись → трогать только в `dev`-дереве,
   не думать о публичном репозитории вообще, пока явно не попросят релиз.
3. Задача про обычный UI/фичу без отношения к обходу → перед `git push origin`
   свериться с 🔴/🟢 списком в §2.
4. После работы — коммит в этом репозитории (в `dev`, guard сам не даст уйти в
   `origin` бесаргументным пушем) + отчёт в `AxiOm_Architecture` (§5).
5. Секреты — никогда в коммит, даже путь к keystore/ключу — см. §4.

---

Связано: `AGENTS_REPO_POLICY.md` и `ONBOARDING.md` в `AxiOm_Architecture`,
`WBSTREAM_SYSTEM.md` §5.0 (граница Telemost/WBStream в деталях), README.md
этого репозитория (сборка, highlights).
