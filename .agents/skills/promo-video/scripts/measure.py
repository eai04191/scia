#!/usr/bin/env python3
"""静止画の、地と違う色の行のかたまり（文字、色の付いた帯）と、地より明るい箱の上下の端を出す。
余白を、見出しの枠ではなく見た目の端で確かめるのに使う。

使い方: python3 measure.py <画像> [左の端 右の端] [地の色 #RRGGBB]
  左右の端（既定は96と984）のあいだの列だけを見る。地の色の既定は#F2F2F7（ライトの地）。
  どの大きさの画像でも読む（座標は画像の画素で出す）。
"""
import json
import subprocess
import sys

args = sys.argv[1:]
path = args[0]
x0, x1 = (int(args[1]), int(args[2])) if len(args) >= 3 else (96, 984)
bg_hex = args[3] if len(args) >= 4 else '#F2F2F7'
bg = tuple(int(bg_hex[i:i + 2], 16) for i in (1, 3, 5))

info = json.loads(subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'json', path], capture_output=True, check=True).stdout)
w, h = info['streams'][0]['width'], info['streams'][0]['height']
x1 = min(x1, w)
raw = subprocess.run(['ffmpeg', '-loglevel', 'error', '-i', path, '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], capture_output=True, check=True).stdout


def px(x, y):
    i = (y * w + x) * 3
    return raw[i], raw[i + 1], raw[i + 2]


def runs(rows):
    out = []
    for y in rows:
        if out and y == out[-1][1] + 1:
            out[-1][1] = y
        else:
            out.append([y, y])
    return [tuple(r) for r in out]


def far(c, ref, d):
    return sum(abs(a - b) for a, b in zip(c, ref)) > d


bright_ref = tuple(min(255, v + 8) for v in bg)
ink, box = [], []
for y in range(h):
    cs = [px(x, y) for x in range(x0, x1)]
    # 地とも白い箱とも違う色の画素があれば、文字や色の付いた帯がある行
    if any(far(c, bg, 90) and far(c, (255, 255, 255), 90) for c in cs):
        ink.append(y)
    # 列の半分以上が地より明るければ、白い箱の行（絵文字が重なる行もあるので半分で見る）
    if sum(1 for c in cs if sum(c) > sum(bright_ref)) > (x1 - x0) / 2:
        box.append(y)
print(f'画像 {w}×{h}、列 {x0}〜{x1}、地 {bg_hex}')
print('地と違う色の行のかたまり（上の端, 下の端）:', runs(ink)[:16])
print('地より明るい行のかたまり（上の端, 下の端）:', runs(box)[:16])
