#!/usr/bin/env bash
# Скачивает ядро sing-box (официальный hiddify-core) в те места, откуда его
# берёт сборка:
#   android  → android/app/libs/hiddify-core.aar
#   windows  → hiddify-core/bin/hiddify-core.dll, libcronet.dll
#
# Ядро мы не пересобираем и не патчим: это релиз апстрима как есть. В git его
# нет — .aar весит 107 МБ, GitHub не принимает файлы больше 100 МБ.
# Версия закреплена вместе с контрольными суммами архивов: другой архив под тем
# же именем скрипт не примет. Меняя версию, берите суммы из API релиза
# (gh release view vX -R hiddify/hiddify-next-core --json assets).
#
# Использование: scripts/fetch_core.sh [android|windows|all]   (по умолчанию all)
set -euo pipefail

CORE_VERSION=4.1.0
BASE_URL="https://github.com/hiddify/hiddify-next-core/releases/download/v${CORE_VERSION}"
SHA_ANDROID=6c4841f7aab23eb1fb17831349ecdfc3ca9c31553b8cbe5effd820cb12607f56
SHA_WINDOWS=fc610e67d9fdf23da7cc10633f38806d7081a1c120157d1fbe5ac8cc41b315b4

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fetch() { # имя-архива ожидаемая-сумма каталог-назначения
  local name=$1 want=$2 dest=$3
  echo "→ $name"
  curl -fL -# --retry 3 -o "$TMP/$name" "$BASE_URL/$name"
  local got
  got=$(sha256 "$TMP/$name")
  if [ "$got" != "$want" ]; then
    echo "✗ контрольная сумма $name не совпала: $got (ждали $want)" >&2
    exit 1
  fi
  mkdir -p "$dest"
  tar xzf "$TMP/$name" -C "$dest"
}

need() {
  [ -f "$1" ] || { echo "✗ после распаковки нет $1" >&2; exit 1; }
}

target=${1:-all}
case "$target" in
  android|windows|all) ;;
  *) echo "использование: $0 [android|windows|all]" >&2; exit 2 ;;
esac
if [ "$target" != windows ]; then
  fetch hiddify-lib-android.tar.gz "$SHA_ANDROID" "$ROOT/android/app/libs"
  need "$ROOT/android/app/libs/hiddify-core.aar"
fi
if [ "$target" != android ]; then
  fetch hiddify-lib-windows-amd64.tar.gz "$SHA_WINDOWS" "$ROOT/hiddify-core/bin"
  need "$ROOT/hiddify-core/bin/hiddify-core.dll"
  need "$ROOT/hiddify-core/bin/libcronet.dll"
fi
echo "✓ ядро hiddify-core v${CORE_VERSION} на месте"
