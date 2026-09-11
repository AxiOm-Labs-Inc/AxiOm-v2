#!/usr/bin/env python3
"""Пересборка иконок трея, баннера Android TV и иконки Linux из нашего знака.

Эталон — windows/runner/resources/app_icon.ico (кадры 16–256, PNG внутри).
Без сторонних библиотек: PNG и ICO читаются и пишутся вручную.

Запуск из корня репозитория:  python3 scripts/make_brand_icons.py
Подробности — docs/REBRANDING.md, §7.
"""
import struct
import zlib

SOURCE = "windows/runner/resources/app_icon.ico"

# Состояния трея: None — знак как есть; цвет — перекраска голубого знака.
TRAY_STATES = {
    "tray_icon": None,
    "tray_icon_dark": None,  # у знака свой тёмный фон — годится для тёмной темы
    "tray_icon_connected": (70, 200, 110),
    "tray_icon_disconnected": (140, 150, 165),
}
TRAY_PNG_SIZE = 128
BANNER = ("android/app/src/main/res/mipmap-xhdpi/ic_banner.png", 320, 180, 128, (6, 10, 22))
LINUX_ICON = ("assets/images/source/ic_launcher_border.png", 256)


def read_ico(path):
    data = open(path, "rb").read()
    (count,) = struct.unpack("<H", data[4:6])
    frames = {}
    for i in range(count):
        w, _, _, _, _, _, size, off = struct.unpack("<BBBBHHII", data[6 + 16 * i:22 + 16 * i])
        frame = data[off:off + size]
        if frame[:8] != b"\x89PNG\r\n\x1a\n":
            raise SystemExit(f"{path}: кадр {w or 256}px не PNG — пересохраните иконку с PNG-кадрами")
        frames[w or 256] = frame
    return frames


def decode_png(png):
    pos, idat = 8, b""
    while pos < len(png):
        (length,) = struct.unpack(">I", png[pos:pos + 4])
        kind, chunk = png[pos + 4:pos + 8], png[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            w, h, depth, color = struct.unpack(">IIBB", chunk[:10])
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + length
    if (depth, color) != (8, 6):
        raise SystemExit("ожидается PNG RGBA 8 бит")
    raw, stride, rows = zlib.decompress(idat), w * 4, []
    prev, p = bytearray(stride), 0
    for _ in range(h):
        filt, line = raw[p], bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for x in range(stride):
            a = line[x - 4] if x >= 4 else 0
            b = prev[x]
            c = prev[x - 4] if x >= 4 else 0
            if filt == 1:
                line[x] = (line[x] + a) & 255
            elif filt == 2:
                line[x] = (line[x] + b) & 255
            elif filt == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif filt == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return w, h, rows


def encode_png(w, h, rows):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def recolor(rows, w, target):
    """Голубые пиксели знака и линий глобуса → целевой цвет с той же яркостью."""
    out = []
    for row in rows:
        row = bytearray(row)
        for x in range(w):
            r, g, b, a = row[x * 4:x * 4 + 4]
            if a and b > 120 and b > r + 40:
                k = min(1.0, b / 224)
                row[x * 4:x * 4 + 3] = bytes(int(c * k) for c in target)
        out.append(row)
    return out


def write_ico(path, pngs):
    header = struct.pack("<HHH", 0, 1, len(pngs))
    offset, entries, body = 6 + 16 * len(pngs), b"", b""
    for size, data in pngs:
        entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset + len(body))
        body += data
    open(path, "wb").write(header + entries + body)


def main():
    frames = read_ico(SOURCE)
    for name, color in TRAY_STATES.items():
        pngs = []
        for size in sorted(frames):
            w, h, rows = decode_png(frames[size])
            if color:
                rows = recolor(rows, w, color)
            pngs.append((size, encode_png(w, h, rows)))
        write_ico(f"assets/images/{name}.ico", pngs)
        open(f"assets/images/{name}.png", "wb").write(dict(pngs)[TRAY_PNG_SIZE])
        print("ok", name)

    path, bw, bh, size, bg = BANNER
    w, h, rows = decode_png(frames[size])
    canvas = [bytearray(bytes(bg) + b"\xff") * bw for _ in range(bh)]
    ox, oy = (bw - w) // 2, (bh - h) // 2
    for y in range(h):
        for x in range(w):
            r, g, b, a = rows[y][x * 4:x * 4 + 4]
            alpha, i = a / 255, (ox + x) * 4
            canvas[oy + y][i:i + 3] = bytes(int(c * alpha + k * (1 - alpha)) for c, k in zip((r, g, b), bg))
    open(path, "wb").write(encode_png(bw, bh, canvas))
    print("ok", path)

    path, size = LINUX_ICON
    open(path, "wb").write(frames[size])
    print("ok", path)


if __name__ == "__main__":
    main()
