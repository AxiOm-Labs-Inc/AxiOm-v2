#!/usr/bin/env bash
# Релизная сборка Android одной командой — так, чтобы собрать неправильно было
# нельзя: без ключа подписи, DEVICE_API_KEY, ядра или librelay.so скрипт
# останавливается до сборки, а не выпускает молча сломанный APK.
#
#   scripts/build_android.sh              # полная сборка
#   scripts/build_android.sh --skip-gen   # без кодогенерации (если модели не менялись)
#
# Результат: dist/AxiOm-v<версия>-arm64.apk (+ все ABI в build/app/outputs/flutter-apk/)
# и отчёт scripts/verify_apk.py. Подробности — docs/BUILD_AND_RELEASE.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

skip_gen=false
[ "${1:-}" = "--skip-gen" ] && skip_gen=true

fail() { echo "✗ $*" >&2; exit 1; }

# --- Что должно лежать до сборки -------------------------------------------
[ -f .env ] || fail "нет .env — скопируйте .env.example и впишите DEVICE_API_KEY"
DEVICE_API_KEY=$(grep -m1 '^DEVICE_API_KEY=' .env | cut -d= -f2- | tr -d '\r[:space:]')
[ -n "$DEVICE_API_KEY" ] || fail "DEVICE_API_KEY в .env пустой"

[ -f android/key.properties ] || fail "нет android/key.properties — см. android/key.properties.example"
store=$(grep -m1 '^storeFile=' android/key.properties | cut -d= -f2- | tr -d '\r')
[ -f "android/app/$store" ] || fail "нет ключа android/app/$store (storeFile из key.properties)"

[ -f android/app/libs/hiddify-core.aar ] || fail "нет ядра android/app/libs/hiddify-core.aar — запустите scripts/fetch_core.sh android"
for abi in arm64-v8a armeabi-v7a; do
  so="android/app/src/main/jniLibs/$abi/librelay.so"
  [ -f "$so" ] || fail "нет $so"
  grep -aq gatedStatus "$so" || fail "$so устаревший (нет gatedStatus) — Телемост работать не будет"
done

PY=""
for c in python3 python py; do
  if "$c" -c 'import zipfile' >/dev/null 2>&1; then PY=$c; break; fi
done
[ -n "$PY" ] || fail "нужен Python 3 для проверки APK"

VERSION=$(grep -m1 '^version:' pubspec.yaml | sed -E 's/version:[[:space:]]*([0-9.]+)\+.*/\1/')
echo "Сборка AxiOm $VERSION"

# --- Сборка ----------------------------------------------------------------
flutter pub get
if ! $skip_gen; then
  # freezed, riverpod, drift и переводы (slang) — *.g.dart в git нет
  dart run build_runner build --delete-conflicting-outputs
fi

# -t lib/main_prod.dart обязателен: точка входа по умолчанию поднимает dev-окружение
flutter build apk --release --split-per-abi -t lib/main_prod.dart \
  --dart-define=DEVICE_API_KEY="$DEVICE_API_KEY"

mkdir -p dist
OUT="dist/AxiOm-v${VERSION}-arm64.apk"
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk "$OUT"

"$PY" scripts/verify_apk.py "$OUT"
echo "✓ Готово: $OUT"
