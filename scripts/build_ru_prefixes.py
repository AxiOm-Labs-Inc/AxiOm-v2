#!/usr/bin/env python3
"""Собрать IPv4-префиксы РФ из RIPE delegated для последующей вшивки в ядро.

Источник: https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-extended-latest
Фильтр: registry ripencc, type ipv4, cc RU, status allocated|assigned.

Не используется приложением в runtime (пока). Выход — текст CIDR и опционально
компактный бинарный список для Go-радикса.

Пример:
  python scripts/build_ru_prefixes.py -o build/ru_prefixes.txt
  python scripts/build_ru_prefixes.py --stats
"""
from __future__ import annotations

import argparse
import ipaddress
import sys
import urllib.request
from pathlib import Path

RIPE_URL = (
    "https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-extended-latest"
)


def parse_ripe(text: str) -> list[str]:
    out: list[str] = []
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        if len(parts) < 7:
            continue
        # ripencc|RU|ipv4|1.2.3.0|256|...|allocated
        if parts[1] != "RU" or parts[2] != "ipv4":
            continue
        if parts[6] not in ("allocated", "assigned"):
            continue
        start = ipaddress.IPv4Address(parts[3])
        count = int(parts[4])
        end = start + count - 1
        # RIPE иногда отдаёт count не степенью двойки — режем на CIDR.
        for net in ipaddress.summarize_address_range(start, end):
            out.append(str(net))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--output", type=Path, help="записать CIDR по одному на строку")
    ap.add_argument("--url", default=RIPE_URL)
    ap.add_argument("--stats", action="store_true", help="только статистика")
    args = ap.parse_args()

    print(f"скачиваю {args.url} …", file=sys.stderr)
    with urllib.request.urlopen(args.url, timeout=120) as resp:
        raw = resp.read().decode("utf-8", errors="replace")

    prefixes = parse_ripe(raw)
    prefixes.sort(key=lambda c: ipaddress.ip_network(c))

    total_hosts = sum(ipaddress.ip_network(c).num_addresses for c in prefixes)
    print(f"префиксов: {len(prefixes)}", file=sys.stderr)
    print(f"адресов (сумма размеров): {total_hosts}", file=sys.stderr)
    if prefixes:
        sample = ", ".join(prefixes[:3])
        print(f"первые: {sample} …", file=sys.stderr)

    if args.stats and not args.output:
        return 0

    if not args.output:
        print("укажите -o FILE или --stats", file=sys.stderr)
        return 2

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(prefixes) + "\n", encoding="utf-8")
    print(f"записано {args.output} ({args.output.stat().st_size} байт)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
