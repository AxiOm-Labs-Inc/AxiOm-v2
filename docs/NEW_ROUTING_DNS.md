# Новая маршрутизация и DNS (РФ)

> Приватный документ. Статус реализации и план. Источник идеи — постановка
> 20.09.2026 (direct с домашнего IP + двухплечевой DNS + форк ядра AxiOm).

**Ветка клиента:** `feat/ru-routing-dns` → remote `dev`  
**Ядро:** `AxiOm-core` (форк), ветка `feat/ru-routing`  
**Выкат:** сначала тест на себе → затем on для всех обновившихся + локальный
kill-switch (настройка) и позже remote при необходимости.

## Цель

Российские ресурсы выходят **мимо туннеля, с домашнего IP**. Разрешение имён
не зависит от одного резолвера и от скачивания remote `geoip-ru.srs`.

## Этапы

| # | Этап | Статус |
|---|------|--------|
| 0 | Диагностика текущего `region=ru` / rule-set / DNS | снято с конфига |
| 1 | Своя сборка ядра as-is (Android/Windows/Linux) | в работе (Android AAR — Linux/CI, на этой машине нет WSL) |
| 2 | Инвентаризация патчей sing-box слоя | в работе |
| 3 | Локальные RU-префиксы + доменные правила | ConfigRule в ядре + списки в клиенте |
| 4 | Пресеты DNS | в клиенте |
| 5 | Двухплечевой DNS | следующий шаг на форке |
| 6 | Автоблок браузерного DoH | после этапа 5 |
| 7 | Переименование внутренностей/бинарей ядра → axiom-core | после зелёной сборки |
| 8 | Релиз / журнал `AxiOm_Architecture` | после приёмки |

## Этап 0 — что уже известно

При `region=ru` ядро кладёт:

```
route: domain_suffix .ru → direct
       rule_set geoip-ru + geosite-ru → direct
dns:   .ru / geosite-ru → dns-direct (local, ipv4_only)
       иначе → dns-remote (tcp 8.8.8.8 через select)
rule_set: remote .srs через download_detour=select, 120h
```

Гипотеза симптома: до первой удачной загрузки rule-set IP-уровень молчит.

## Клиент (эта ветка)

1. **Регион** зафиксирован в `ru` (UI скрыт, prefs v8).
2. **Пресеты DNS** расширены; дефолт direct = `local`.
3. **Тумблер** «Умная маршрутизация РФ» → `new-routing-enabled` (дефолт **off**,
   пока в APK стоковое AAR). Вкл → шлёт `SingboxRule` со строкой `domains`
   (`ru_direct_domains.dart`). Kill-switch без переустановки.
4. **Фикс селектора** стран/протоколов: группа outbounds держится по тегу.
5. **Таймаут** обновления подписки перед коннектом (20 с).
6. **Скрипт** `scripts/build_ru_prefixes.py` — RIPE → префиксы для вшивки в ядро.
7. Prefs v9 откатывает опасный resolve-destination / new-routing у пробных сборок.

## Ядро (AxiOm-core)

- `ConfigRule` с `domains` **строкой** (как шлёт клиент) — отдельно от protobuf `Rule`.
- `applyConfigRules` снова вызывает сборку route/DNS правил (раньше цикл был выключен).
- Сборка Android AAR: `make android` (нужен Linux/WSL + gomobile). Windows-машина
  владельца без WSL — собирать на CI или Linux-хосте, затем положить
  `axiom-core.aar` / `hiddify-core.aar` в `android/app/libs/` клиента.

## Что ещё нельзя без доработки ядра

- Локальный радикс RU-префиксов вместо remote geoip
- Двухплечевой DNS (гонка direct/remote + фильтр по RU IP)
- Автоблок DoH
- Кэш решения домен→direct|tunnel

## Критерии приёмки

- 15–20 URL до/после; дом / мобильный / чужой Wi‑Fi
- Android + Windows + Linux
- Отказы: мёртвый direct DNS, смена сети, недоступный remote geoip
- Kill-switch возвращает прежнее поведение клиента
