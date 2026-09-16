#!/usr/bin/env python3
"""Проверка готового APK перед тем, как отдавать его людям.

Каждая проверка здесь — след реального выпуска, ушедшего сломанным без единой
ошибки сборки:
  * версия          — APK с тем же versionCode не встаёт поверх установленного;
  * подпись         — чужой ключ = обновление не ставится, только переустановка;
  * main_prod       — без -t lib/main_prod.dart все сборки до 04.09.2026 были dev
                      (подробные логи у всех, падение вместо восстановления префов);
  * DEVICE_API_KEY  — без ключа счётчик устройств тихо пропадает (4.3.x);
  * адрес лимитера  — ловит откат на мёртвый vpn.arcohouse.space;
  * librelay.so     — устаревший relay без gatedStatus = нерабочий Телемост
                      (4.4.1–4.4.3);
  * утечка механики — адреса WB/Диска должны жить только в librelay.so.

Использование:
  python scripts/verify_apk.py [путь-к-apk]
По умолчанию — build/app/outputs/flutter-apk/app-arm64-v8a-release.apk.
Ключ для сверки берётся из .env (DEVICE_API_KEY) в корне репозитория.
"""
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_APK = ROOT / "build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
# SHA-256 сертификата подписи AxiOm. Это отпечаток публичного сертификата,
# он виден в любом выпущенном APK — не секрет.
CERT_SHA256 = "63c8ce05227967b4d20de5f2c039d70eecb599c9b66e9e7147066cd48c44f942"
LEAK_MARKERS = [b"stream.wb.ru", b"yadi.sk"]

failures = []


def check(ok, what, detail=""):
    print(("  ✓ " if ok else "  ✗ ") + what + (f" — {detail}" if detail else ""))
    if not ok:
        failures.append(what)


def pubspec_version():
    m = re.search(r"^version:\s*([\d.]+)\+(\d+)", (ROOT / "pubspec.yaml").read_text("utf-8"), re.M)
    return m.group(1), m.group(2)


def env_key():
    env = ROOT / ".env"
    if not env.exists():
        return None
    for line in env.read_text("utf-8").splitlines():
        if line.startswith("DEVICE_API_KEY="):
            return line.split("=", 1)[1].strip() or None
    return None


def build_tools():
    candidates = [os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT")]
    if os.environ.get("LOCALAPPDATA"):
        candidates.append(os.path.join(os.environ["LOCALAPPDATA"], "Android", "Sdk"))
    candidates.append(os.path.expanduser("~/Android/Sdk"))
    candidates.append(os.path.expanduser("~/Library/Android/sdk"))
    for sdk in filter(None, candidates):
        bt = Path(sdk) / "build-tools"
        if bt.is_dir():
            versions = sorted(bt.iterdir(), key=lambda p: [int(x) if x.isdigit() else 0 for x in re.split(r"[.-]", p.name)])
            if versions:
                return versions[-1]
    return None


def tool(bt, name):
    for suffix in (".exe", ".bat", ""):
        p = bt / (name + suffix)
        if p.exists():
            return str(p)
    return None


def main():
    # Консоль Windows по умолчанию в cp1251/cp1252 — без этого падает на «✓».
    sys.stdout.reconfigure(encoding="utf-8")
    apk = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_APK
    if not apk.exists():
        sys.exit(f"нет файла {apk}")
    print(f"Проверяю {apk}")
    want_name, want_code = pubspec_version()

    bt = build_tools()
    if bt is None:
        check(False, "Android SDK build-tools", "не найдены (задайте ANDROID_HOME)")
    else:
        aapt2 = tool(bt, "aapt2")
        badging = subprocess.run([aapt2, "dump", "badging", str(apk)], capture_output=True, text=True, encoding="utf-8", errors="replace").stdout
        m = re.search(r"versionCode='(\d+)' versionName='([^']+)'", badging)
        got = (m.group(2), m.group(1)) if m else ("?", "?")
        check(got == (want_name, want_code), "версия совпадает с pubspec.yaml", f"APK {got[0]}+{got[1]}, pubspec {want_name}+{want_code}")

        apksigner = tool(bt, "apksigner")
        out = subprocess.run([apksigner, "verify", "--print-certs", str(apk)], capture_output=True, text=True, shell=apksigner.endswith(".bat")).stdout
        m = re.search(r"certificate SHA-256 digest: ([0-9a-f]+)", out)
        check(bool(m) and m.group(1) == CERT_SHA256, "подпись ключом AxiOm", m.group(1)[:16] + "…" if m else "подпись не прочитана")

    with zipfile.ZipFile(apk) as z:
        names = z.namelist()
        libapp = next((n for n in names if n.endswith("/libapp.so")), None)
        relay = next((n for n in names if n.endswith("/librelay.so")), None)
        if libapp is None:
            check(False, "libapp.so в APK")
            sys.exit(1)
        data = z.read(libapp)
        check(b"main_prod" in data, "собрано из lib/main_prod.dart")
        key = env_key()
        if key:
            check(key.encode() in data, "DEVICE_API_KEY вкомпилирован")
        else:
            check(False, "DEVICE_API_KEY вкомпилирован", "нет ключа в .env — сверить не с чем")
        check(b"fr.arcohouse.space/devices" in data, "адрес лимитера устройств — FR")
        leaked = [m.decode() for m in LEAK_MARKERS if m in data]
        check(not leaked, "в Dart-коде нет адресов механики Телемоста", ", ".join(leaked))
        if relay is None:
            check(False, "librelay.so в APK")
        else:
            check(b"gatedStatus" in z.read(relay), "librelay.so свежий (есть gatedStatus)")

    if failures:
        print(f"\n✗ Не прошло проверок: {len(failures)}. Такой APK отдавать нельзя.")
        sys.exit(1)
    print("\n✓ Все проверки пройдены.")


if __name__ == "__main__":
    main()
