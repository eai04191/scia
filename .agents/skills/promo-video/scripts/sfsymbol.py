#!/usr/bin/env python3
"""SF Symbolsのテンプレート（SF Symbolsアプリの「テンプレートを書き出す」）から、Regular-Sの形を取り出してSVGにする。

使い方: python3 sfsymbol.py <シンボルの名前> <大きさ(px)> [テンプレートのフォルダー]
  例: python3 sfsymbol.py arrow.up 34 > arrow.up.svg

文字の高さを基準に、どのシンボルも同じ枠（幅と高さ96、上の端-83）に置くので、シンボルどうしの大きさの違いが残る。
形ごとの外接矩形で枠を決めると、＋のような小さいシンボルまで地球と同じ大きさになるため、そうしない。
色は fill="currentColor" なので、親の color で決める。
"""
import os
import re
import sys

name, size = sys.argv[1], int(sys.argv[2])
folder = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser('~/Documents/sfsymbols/symbol')
s = open(os.path.join(folder, name + '.svg')).read()
if 'id="Regular-S"' not in s:
    sys.exit(f'{name}.svg に Regular-S のグループがない。SF Symbolsアプリでテンプレートを書き出し直す')
i = s.index('id="Regular-S"')
j = s.index('</g>', i)
ds = re.findall(r' d="([^"]+)"', s[i:j])

# 横の中心を出すため、パスのx座標だけを集める。テンプレートは絶対座標のM、L、C、Q、Zで書かれている。
# それ以外のコマンドが出たら、中心を誤るので止める
xs = []
for d in ds:
    for cmd, body in re.findall(r'([A-Za-z])([^A-Za-z]*)', d):
        nums = [float(v) for v in re.findall(r'-?\d+\.?\d*(?:e-?\d+)?', body)]
        if cmd in 'MLCQ':
            xs += nums[0::2]
        elif cmd == 'Z':
            pass
        else:
            sys.exit(f'{name}.svg に対応していないパスのコマンド {cmd} がある')
cx = (min(xs) + max(xs)) / 2
paths = ''.join(f'<path d="{d}"/>' for d in ds)
print(f'<svg width="{size}" height="{size}" viewBox="{cx - 48:.2f} -83 96 96" fill="currentColor">{paths}</svg>')
