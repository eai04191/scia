#!/usr/bin/env python3
"""実サーバーのカスタム絵文字から、動画に使う素材を作る。

使い方: python3 emoji_assets.py <サーバー> <出力フォルダー> [--category <正規表現>] [--count 720] [--cache <フォルダー>]
  例: python3 emoji_assets.py fedibird.com /abs/work/fe --category '^blob|^bun$'

書くもの:
  <出力>/big/0000.png …   128pxの画像（くっきりした元の絵として使う）
  <出力>/small/0000.png … 15pxに縮めた画像（サムネイルとして使う。表示するときに拡大して粗く見せる）
  <出力>/meta.js         … window.CATS（番号ごとのカテゴリ）と window.SRVORDER（サーバーの応答の順に並べた番号）

決まり:
  - api/v1/custom_emojis の、visible_in_picker のものだけを使う
  - 並びは実物の絵文字パレットと同じ（EmojiPalette.swift）。カテゴリの名前の順（大文字小文字を区別しない）、カテゴリの中はサーバーの応答の順
  - 縦横が1:1のものだけ（--any-aspect で外せる）
  - 動かない版（static_url）の画像を使う。ほぼ透明な画像（動く絵文字の最初のコマが透明なもの）は除く。
    プロモーションで透明な画像を画像として扱うと、意図が伝わらないため
変換には macOS の sips と ffmpeg を使う。
"""
import argparse
import json
import os
import re
import subprocess
import urllib.request

ap = argparse.ArgumentParser()
ap.add_argument('server')
ap.add_argument('out')
ap.add_argument('--category', default='')
ap.add_argument('--count', type=int, default=720)
ap.add_argument('--cache', default=None, help='取得した画像を置くフォルダー（既定は<出力>/cache）')
ap.add_argument('--any-aspect', action='store_true')
a = ap.parse_args()

out = os.path.abspath(a.out)
cache = os.path.abspath(a.cache or os.path.join(out, 'cache'))
for d in (out, cache, os.path.join(out, 'big'), os.path.join(out, 'small')):
    os.makedirs(d, exist_ok=True)

req = urllib.request.Request(f'https://{a.server}/api/v1/custom_emojis', headers={'User-Agent': 'promo-video-assets'})
emojis = json.load(urllib.request.urlopen(req))
cat_re = re.compile(a.category) if a.category else None
picked = [(i, e) for i, e in enumerate(emojis) if e.get('visible_in_picker') and (not cat_re or cat_re.search(e.get('category') or ''))]
# カテゴリの名前の順（大文字小文字を区別しない）。カテゴリの中はサーバーの応答の順（sortは安定）
picked.sort(key=lambda p: (p[1].get('category') or '').lower())


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, check=True).stdout


def size_of(p):
    s = run('sips', '-g', 'pixelWidth', '-g', 'pixelHeight', p).decode()
    return int(re.search(r'pixelWidth: (\d+)', s).group(1)), int(re.search(r'pixelHeight: (\d+)', s).group(1))


def mean_alpha(p):
    return run('ffmpeg', '-loglevel', 'error', '-i', p, '-vf', 'format=rgba,scale=1:1:flags=area', '-f', 'rawvideo', '-')[3]


meta = []
skipped = {'aspect': 0, 'transparent': 0, 'error': 0}
for idx, e in picked:
    if len(meta) >= a.count:
        break
    url = e['static_url']
    src = os.path.join(cache, re.sub(r'[^A-Za-z0-9._-]', '_', url.rsplit('/', 1)[-1]))
    try:
        if not os.path.exists(src):
            # User-Agentがないと、画像の配信元が403を返すことがある
            data = urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'promo-video-assets'})).read()
            open(src, 'wb').write(data)
        w, h = size_of(src)
        if not a.any_aspect and w != h:
            skipped['aspect'] += 1
            continue
        n = f'{len(meta):04d}'
        big, small = os.path.join(out, 'big', n + '.png'), os.path.join(out, 'small', n + '.png')
        run('sips', '-s', 'format', 'png', '-Z', '128', src, '--out', big)
        if mean_alpha(big) < 8:
            skipped['transparent'] += 1
            continue
        run('sips', '-s', 'format', 'png', '-Z', '15', big, '--out', small)
        meta.append((idx, e.get('category') or ''))
    except Exception as err:  # 取得や変換に失敗した絵文字は数えて飛ばす
        skipped['error'] += 1
        print('失敗:', e.get('shortcode'), err)
        if skipped['error'] >= 10 and not meta:
            raise SystemExit('取得か変換が続けて失敗した。サーバーとネットワークを確かめる')

srv = sorted(range(len(meta)), key=lambda k: meta[k][0])
with open(os.path.join(out, 'meta.js'), 'w') as f:
    f.write('window.CATS=' + json.dumps([c for _, c in meta], ensure_ascii=False) + ';window.SRVORDER=' + json.dumps(srv) + ';')
print(f'{len(meta)}個を書いた。除いたもの: {skipped}')
