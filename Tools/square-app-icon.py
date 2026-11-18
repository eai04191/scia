"""アプリのアイコン（.icon）から、角まで絵の詰まった四角の絵を書き出すための.iconを作る。

ictoolはホーム画面と同じ角丸で切り抜いて書き出し、切り抜かずに書き出すオプションがない。
そこで、レイヤーを`scale`倍に縮め、地のグラデーションの始点と終点も同じ割合で真ん中に寄せた.iconを作る。
これを書き出して真ん中の`scale`の範囲を切り出すと、元のアイコンと同じ絵を、角丸の切り抜きと縁の線にかからずに取り出せる。

使い方: python3 Tools/square-app-icon.py <元の.icon> <作る.icon> <scale>
"""

import json
import shutil
import sys


def shrink_point(point, scale):
    return {axis: 0.5 + (point[axis] - 0.5) * scale for axis in ("x", "y")}


def main():
    source, output, scale = sys.argv[1], sys.argv[2], float(sys.argv[3])
    shutil.copytree(source, output)
    path = f"{output}/icon.json"
    with open(path) as file:
        icon = json.load(file)

    fill = icon.get("fill", {})
    if "linear-gradient" in fill:
        orientation = fill["orientation"]
        for end in ("start", "stop"):
            orientation[end] = shrink_point(orientation[end], scale)
    elif "solid" not in fill:
        sys.exit(f"error: {path}の地（fill）の形に対応していません: {list(fill)}")

    for group in icon["groups"]:
        if "position" in group:
            sys.exit(f"error: {path}のグループの位置（position）には対応していません: {group['name']}")
        for layer in group["layers"]:
            position = layer.setdefault("position", {"scale": 1, "translation-in-points": [0, 0]})
            position["scale"] = position["scale"] * scale
            position["translation-in-points"] = [value * scale for value in position["translation-in-points"]]

    with open(path, "w") as file:
        json.dump(icon, file, indent=2)


main()
