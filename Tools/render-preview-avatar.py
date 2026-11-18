"""「投稿の見た目」の見本のアイコンとカスタム絵文字に使う絵を、アプリのアイコン（.icon）から書き出す。
静止画は、角まで絵の詰まった512pxの四角の絵。アニメーション版は、軌跡（trail.svg）が蛇の尻尾のようにうねるHEVCの動画で、最初のコマが静止画と同じ絵になる。
アプリは、動画を読んでAPNGにしてから見本に使う（App/Sources/Settings/PreviewImages.swift）。APNGのままアプリに入れると約4MBになるため。

ictoolはホーム画面と同じ角丸で切り抜いて書き出し、切り抜かずに書き出すオプションがない。
そこで、レイヤーを0.75倍に縮め、地のグラデーションの始点と終点も同じ割合で真ん中に寄せた.iconを書き出して、真ん中の0.75の範囲を切り出す。
0.75は、角丸の切り抜きと縁の線が切り出す範囲に入らない倍率（180pxの書き出しで、角の対角線上の13pxまでが透明で、その内側に縁の線がある）。
コマはictoolで1枚ずつ書き出すので、軌跡の影やガラスの光り方も、曲がった形に合わせて付く。

使い方: python3 Tools/render-preview-avatar.py <ictool> <元の.icon> <作業フォルダー> <静止画の出力> <動画の出力>
"""

import json
import math
import re
import shutil
import os
import platform
import subprocess
import sys

SCALE = 0.75
# 1024pxで書き出し、真ん中の768pxを切り出して、アイコンの大きさの上限（200pt）の@3xに近い512pxにする。
EXPORT_SIDE = 1024
SIDE = 512
TRAIL = "trail.svg"
# うねる動き。止まっている時間のあと、動く時間のあいだに、なだらかに揺れ始めて収まる。
# コマの長さは1/100秒の単位で決める。アイコンの再生（AvatarImageStore）が1/100秒に丸めるため、割り切れないとアイコンだけ速さが変わる。
HOLD_CENTISECONDS = 170
MOVE_FRAMES = 40
MOVE_FRAME_CENTISECONDS = 3
# 揺れの大きさ（1024ptのアイコンでのpt）と、軌跡に沿って並ぶ波の数、動く時間に波が流れる周期の数。
AMPLITUDE = 45
WAVES = 1.0
WAVE_CYCLES = 1.5
# 尻尾（左下）の側ほど大きく揺らす。頭（右上）での揺れの、尻尾に対する割合。
HEAD_REACH = 0.75


def fail(message):
    sys.exit(f"error: {message}")


def shrink_point(point):
    return {axis: 0.5 + (point[axis] - 0.5) * SCALE for axis in ("x", "y")}


def shrunk_icon(icon, path):
    fill = icon.get("fill", {})
    if "linear-gradient" in fill:
        orientation = fill["orientation"]
        for end in ("start", "stop"):
            orientation[end] = shrink_point(orientation[end])
    elif "solid" not in fill:
        fail(f"{path}の地（fill）の形に対応していません: {list(fill)}")
    for group in icon["groups"]:
        if "position" in group:
            fail(f"{path}のグループの位置（position）には対応していません: {group['name']}")
        for layer in group["layers"]:
            position = layer.setdefault("position", {"scale": 1, "translation-in-points": [0, 0]})
            position["scale"] = position["scale"] * SCALE
            position["translation-in-points"] = [value * SCALE for value in position["translation-in-points"]]
    return icon


class Trail:
    """軌跡の輪郭。片側の縁が右上の端まで行き、もう片側の縁で戻る、直線でつないだ点の列。"""

    def __init__(self, svg, path):
        self.svg = svg
        points = [(float(x), float(y)) for x, y in re.findall(r"[ML] (-?[\d.]+) (-?[\d.]+)", svg)]
        if len(points) < 4 or svg.count(' d="') != 1:
            fail(f"{path}の形に対応していません。点を直線でつないだ1つのpathにしてください")
        turn = max(range(len(points)), key=lambda index: points[index][0])
        self.forward = points[: turn + 1]
        self.backward = points[turn + 1 :][::-1]
        self.forward_fractions = self.fractions(self.forward)
        self.backward_fractions = self.fractions(self.backward)

    @staticmethod
    def fractions(edge):
        lengths = [0.0]
        for start, end in zip(edge, edge[1:]):
            lengths.append(lengths[-1] + math.dist(start, end))
        return [length / lengths[-1] for length in lengths]

    @staticmethod
    def point(edge, fractions, fraction):
        for index in range(1, len(fractions)):
            if fractions[index] >= fraction:
                span = fractions[index] - fractions[index - 1]
                ratio = (fraction - fractions[index - 1]) / span if span else 0
                start, end = edge[index - 1], edge[index]
                return (start[0] + (end[0] - start[0]) * ratio, start[1] + (end[1] - start[1]) * ratio)
        return edge[-1]

    def center(self, fraction):
        forward = self.point(self.forward, self.forward_fractions, fraction)
        backward = self.point(self.backward, self.backward_fractions, fraction)
        return ((forward[0] + backward[0]) / 2, (forward[1] + backward[1]) / 2)

    def normal(self, fraction):
        step = 0.002
        before = self.center(max(fraction - step, 0))
        after = self.center(min(fraction + step, 1))
        dx, dy = after[0] - before[0], after[1] - before[1]
        length = math.hypot(dx, dy)
        return (-dy / length, dx / length)

    @staticmethod
    def offset(fraction, progress):
        # 頭（右上）から尻尾（左下）へ流れる波。動き始めと終わりは0にして、静止画の形へ戻す。
        envelope = math.sin(math.pi * progress) ** 2
        reach = HEAD_REACH + (1 - HEAD_REACH) * (1 - fraction)
        return AMPLITUDE * envelope * reach * math.sin(2 * math.pi * (WAVES * fraction + WAVE_CYCLES * progress))

    def bent(self, progress):
        def move(edge, fractions):
            moved = []
            for point, fraction in zip(edge, fractions):
                normal = self.normal(fraction)
                offset = self.offset(fraction, progress)
                moved.append((point[0] + normal[0] * offset, point[1] + normal[1] * offset))
            return moved

        outline = move(self.forward, self.forward_fractions) + move(self.backward, self.backward_fractions)[::-1]
        d = "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in outline) + " Z"
        return re.sub(r' d="[^"]*"', f' d="{d}"', self.svg)


def main():
    ictool, source, work, still_output, video_output = sys.argv[1:6]
    with open(f"{source}/icon.json") as file:
        base = json.load(file)
    layers = [layer for group in base["groups"] for layer in group["layers"] if layer.get("image-name") == TRAIL]
    if len(layers) != 1:
        fail(f"{source}に、うねらせる軌跡（{TRAIL}）のレイヤーが1つだけあるようにしてください")
    with open(f"{source}/Assets/{TRAIL}") as file:
        trail = Trail(file.read(), f"{source}/Assets/{TRAIL}")

    frames = []
    for index in range(MOVE_FRAMES + 1):
        icon_path = f"{work}/frame{index}.icon"
        shutil.copytree(source, icon_path)
        with open(f"{icon_path}/Assets/{TRAIL}", "w") as file:
            file.write(trail.bent(index / (MOVE_FRAMES + 1)))
        with open(f"{icon_path}/icon.json") as file:
            icon = shrunk_icon(json.load(file), f"{source}/icon.json")
        with open(f"{icon_path}/icon.json", "w") as file:
            json.dump(icon, file)
        exported = f"{work}/exported{index}.png"
        cropped = f"{work}/cropped{index}.png"
        frame = f"{work}/frame{index}.png"
        subprocess.run(
            [ictool, icon_path, "--export-image", "--output-file", exported, "--platform", "iOS", "--rendition", "Default",
             "--width", str(EXPORT_SIDE), "--height", str(EXPORT_SIDE), "--scale", "1"],
            check=True, stdout=subprocess.DEVNULL,
        )
        crop = str(int(EXPORT_SIDE * SCALE))
        subprocess.run(["sips", "--cropToHeightWidth", crop, crop, exported, "--out", cropped], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["sips", "--resampleHeightWidth", str(SIDE), str(SIDE), cropped, "--out", frame], check=True, stdout=subprocess.DEVNULL)
        frames.append(frame)

    shutil.copyfile(frames[0], still_output)
    durations = [HOLD_CENTISECONDS] + [MOVE_FRAME_CENTISECONDS] * MOVE_FRAMES
    encoder = os.path.join(os.path.dirname(os.path.abspath(__file__)), "encode-preview-avatar.swift")
    # ビルドの手順はiOSのSDKを指しているので、macOSのSDKで走らせる。
    # macOS 26向けとして動かす。書き出しに使うAVAssetWriterのAPIはmacOS 27で非推奨になり、代わりのAPIはCoreVideoの新しい型を前提にするため。
    environment = {key: value for key, value in os.environ.items() if key != "SDKROOT"}
    target = f"{platform.machine()}-apple-macos26.0"
    subprocess.run(
        ["xcrun", "--sdk", "macosx", "swift", "-target", target, encoder, video_output] + [f"{duration}:{frame}" for duration, frame in zip(durations, frames)],
        check=True, env=environment,
    )


main()
