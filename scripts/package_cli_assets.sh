#!/usr/bin/env bash
# Архивы CLI для обновления старого Go-CLI AxiOm (cli-v0.0.x) до SBX.
#
# Старый `axiom update` берёт первый релиз AxiOm-v2 с ассетом AxiOm-cli-<os>-amd64.(tar.gz|zip)
# и распаковывает его поверх своей папки. Поэтому к релизу приложения прикладываются:
#   AxiOm-cli-linux-amd64.tar.gz  — один файл `axiom` (= sbx.py, права 0755);
#   AxiOm-cli-windows-amd64.zip   — один файл `axiom.exe` (= sbx-windows-amd64.exe).
# Файлы берутся из релиза SBX (не старше 1.4.0) и сверяются с sha256 из GitHub API (поле digest).
#
# Использование:
#   scripts/package_cli_assets.sh [-o КАТАЛОГ] [--sbx-tag vX.Y.Z] [--upload ТЕГ_РЕЛИЗА_AXIOM]
# Переменные: SBX_REPO (по умолчанию Xenon-Tetraoxide/SBX-VPN-Client),
#             APP_REPO (по умолчанию AxiOm-Labs-Inc/AxiOm-v2). Нужны gh, tar (GNU), python3, sha256sum.
set -euo pipefail

SBX_REPO=${SBX_REPO:-Xenon-Tetraoxide/SBX-VPN-Client}
APP_REPO=${APP_REPO:-AxiOm-Labs-Inc/AxiOm-v2}
out_dir=dist/cli-assets
sbx_tag=latest
upload_tag=

die() { echo "package_cli_assets: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out) [ $# -ge 2 ] || die "нет значения для $1"; out_dir=$2; shift 2 ;;
    --sbx-tag) [ $# -ge 2 ] || die "нет значения для $1"; sbx_tag=$2; shift 2 ;;
    --upload) [ $# -ge 2 ] || die "нет значения для $1"; upload_tag=$2; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

for tool in gh tar python3 sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || die "не найден $tool"
done

if [ "$sbx_tag" = latest ]; then
  release_api="repos/$SBX_REPO/releases/latest"
else
  release_api="repos/$SBX_REPO/releases/tags/$sbx_tag"
fi
resolved_tag=$(gh api "$release_api" --jq '.tag_name')
[ -n "$resolved_tag" ] || die "не найден релиз SBX ($release_api)"
echo "SBX: $SBX_REPO $resolved_tag"

# Синхронизация с приложением (cli-sync) есть только в SBX >= 1.4.0 — старее не упаковываем.
if ! [[ "$resolved_tag" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  die "тег релиза SBX не вида vX.Y.Z: $resolved_tag"
fi
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]}
if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 4 ]; }; then
  die "SBX $resolved_tag старше 1.4.0: в нём нет синхронизации с приложением; упаковка отменена"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/download" "$work/linux" "$work/windows" "$out_dir"

fetch() { # имя ассета -> $work/download/<имя>, с проверкой sha256
  local name=$1 digest expected actual
  digest=$(gh api "repos/$SBX_REPO/releases/tags/$resolved_tag" \
    --jq ".assets[] | select(.name == \"$name\") | .digest // \"\"")
  case "$digest" in
    sha256:*) expected=${digest#sha256:} ;;
    *) die "у ассета $name релиза $resolved_tag нет sha256 в API (digest: '${digest}')" ;;
  esac
  gh release download "$resolved_tag" -R "$SBX_REPO" -p "$name" -D "$work/download" --clobber
  actual=$(sha256sum "$work/download/$name" | cut -d' ' -f1)
  [ "$actual" = "$expected" ] || die "sha256 $name не совпал: $actual != $expected"
  echo "  $name sha256 $actual — совпадает с API"
}

fetch sbx.py
fetch sbx-windows-amd64.exe

cp "$work/download/sbx.py" "$work/linux/axiom"
chmod 0755 "$work/linux/axiom"
cp "$work/download/sbx-windows-amd64.exe" "$work/windows/axiom.exe"

linux_archive="$out_dir/AxiOm-cli-linux-amd64.tar.gz"
windows_archive="$out_dir/AxiOm-cli-windows-amd64.zip"
tar --owner=0 --group=0 --numeric-owner --mode=0755 -C "$work/linux" -czf "$linux_archive" axiom
python3 - "$work/windows/axiom.exe" "$windows_archive" <<'PY'
import sys, zipfile, time
src, dst = sys.argv[1], sys.argv[2]
info = zipfile.ZipInfo("axiom.exe", date_time=time.localtime()[:6])
info.compress_type = zipfile.ZIP_DEFLATED
info.external_attr = 0o100755 << 16
with open(src, "rb") as f, zipfile.ZipFile(dst, "w") as z:
    z.writestr(info, f.read())
PY

echo "Готово:"
ls -l "$linux_archive" "$windows_archive"

if [ -n "$upload_tag" ]; then
  gh release upload "$upload_tag" -R "$APP_REPO" --clobber "$linux_archive" "$windows_archive"
  echo "Загружено в $APP_REPO $upload_tag"
fi
