#!/usr/bin/env python3
"""Generate the original 子川 activity mark as compact white-alpha sprite sheets."""
from __future__ import annotations

import json
import math
import struct
import zlib
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
OUT = APP / "assets" / "whale"
FRAME_W, FRAME_H, COLUMNS = 120, 96, 6
SUPERSAMPLE = 3
Y0, Y1 = 12.0, 84.0
BASE_X = (38.0, 60.0, 82.0)
RADIUS = 3.7


def chunk(kind: bytes, data: bytes) -> bytes:
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def write_png(path: Path, width: int, height: int, pixels: bytes) -> None:
    rows = b"".join(b"\x00" + pixels[y * width * 4:(y + 1) * width * 4] for y in range(height))
    payload = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">2I5B", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows, 9))
        + chunk(b"IEND", b"")
    )
    path.write_bytes(payload)


def point(base: float, amplitude: float, phase: float, stroke: int, y: float) -> tuple[float, float]:
    t = (y - Y0) / (Y1 - Y0) * math.tau + phase + stroke * math.tau / 3
    return base + amplitude * math.sin(t), amplitude * math.tau / (Y1 - Y0) * math.cos(t)


def render_frame(amplitude: float, phase: float) -> bytes:
    out = bytearray(FRAME_W * FRAME_H * 4)
    for py in range(FRAME_H):
        for px in range(FRAME_W):
            inside = 0
            for sy in range(SUPERSAMPLE):
                y = py + (sy + 0.5) / SUPERSAMPLE
                for sx in range(SUPERSAMPLE):
                    x = px + (sx + 0.5) / SUPERSAMPLE
                    covered = False
                    for stroke, base in enumerate(BASE_X):
                        if y < Y0:
                            cx, _ = point(base, amplitude, phase, stroke, Y0)
                            distance = math.hypot(x - cx, y - Y0)
                        elif y > Y1:
                            cx, _ = point(base, amplitude, phase, stroke, Y1)
                            distance = math.hypot(x - cx, y - Y1)
                        else:
                            cx, slope = point(base, amplitude, phase, stroke, y)
                            distance = abs(x - cx) / math.sqrt(1 + slope * slope)
                        if distance <= RADIUS:
                            covered = True
                            break
                    inside += int(covered)
            alpha = round(inside * 255 / (SUPERSAMPLE * SUPERSAMPLE))
            offset = (py * FRAME_W + px) * 4
            out[offset:offset + 4] = bytes((255, 255, 255, alpha))
    return bytes(out)


def sheet(amplitude: float, frames: int) -> tuple[int, int, bytes]:
    rows = math.ceil(frames / COLUMNS)
    width, height = FRAME_W * COLUMNS, FRAME_H * rows
    image = bytearray(width * height * 4)
    for index in range(frames):
        phase = math.tau * index / frames if frames > 1 else 0.0
        frame = render_frame(amplitude, phase)
        x0, y0 = index % COLUMNS * FRAME_W, index // COLUMNS * FRAME_H
        for y in range(FRAME_H):
            source = y * FRAME_W * 4
            dest = ((y0 + y) * width + x0) * 4
            image[dest:dest + FRAME_W * 4] = frame[source:source + FRAME_W * 4]
    return width, height, bytes(image)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    specs = (
        (1, 0.0, 1, 0, "static river mark"),
        (2, 1.7, 24, 32, "slow flow"),
        (3, 3.2, 24, 24, "steady flow"),
        (4, 5.0, 36, 16, "quick flow"),
    )
    levels = []
    for level, amplitude, frames, frame_ms, source in specs:
        image = f"whale_{level}.png"
        width, height, pixels = sheet(amplitude, frames)
        write_png(OUT / image, width, height, pixels)
        levels.append({"level": level, "image": image, "frames": frames, "frameMs": frame_ms, "source": source})
        print(f"wrote {image}: {width}x{height}, {frames} frames")
    manifest = {
        "frameWidth": FRAME_W,
        "frameHeight": FRAME_H,
        "columns": COLUMNS,
        "levels": levels,
    }
    (OUT / "whale.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {OUT / 'whale.json'}")


if __name__ == "__main__":
    main()
