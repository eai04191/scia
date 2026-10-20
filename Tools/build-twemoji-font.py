# /// script
# requires-python = ">=3.12"
# dependencies = ["nanoemoji==0.16.0"]
# ///
"""twemojiのSVGから、本文の絵文字をtwemojiで描くための書体（COLRv0）を作る。

jdecked/twemojiの指定した版のSVGを取り、Unicodeの絵文字の一覧（emoji-test.txt）にある並びを、
異体字セレクター（U+FE0F）の有無を問わず同じ絵に当てる。twemojiのファイル名は、ZWJを含まない並びからU+FE0Fを除き、
ZWJを含む並びでは絵ごとにU+FE0Fを残したり除いたりしているが、投稿の本文にはどちらの並び（「❤️」と「❤」、「🏃‍♀️」と「🏃‍♀」）も来るため、
U+FE0Fをすべて除いた並びで絵を探し、本文に来うる並びをすべて合字で引けるようにする。

COLRv0にするのは、iOSのCoreTextが描けると確かめた形式のため。twemojiはグラデーションを使わないので、COLRv1でなくても絵は変わらない。

使い方: uv run Tools/build-twemoji-font.py
"""

import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

TWEMOJI_VERSION = "v17.0.3"
UNICODE_EMOJI_VERSION = "17.0"
OUTPUT = Path("App/Resources/Twemoji.ttf")

VS16 = 0xFE0F


def without_vs16(codepoints: list[int]) -> tuple[int, ...]:
    return tuple(cp for cp in codepoints if cp != VS16)


def emoji_sequences() -> list[list[int]]:
    url = f"https://www.unicode.org/Public/{UNICODE_EMOJI_VERSION}.0/emoji/emoji-test.txt"
    with urllib.request.urlopen(url) as response:
        text = response.read().decode()
    sequences = []
    for line in text.splitlines():
        if not line or line.startswith("#") or ";" not in line:
            continue
        sequences.append([int(cp, 16) for cp in line.split(";")[0].split()])
    return sequences


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        repo = work / "twemoji"
        subprocess.run(
            ["git", "clone", "-q", "--depth", "1", "--branch", TWEMOJI_VERSION, "--filter=blob:none", "--sparse",
             "https://github.com/jdecked/twemoji.git", str(repo)],
            check=True,
        )
        subprocess.run(["git", "-C", str(repo), "sparse-checkout", "set", "assets/svg"], check=True)
        svgs = {
            without_vs16([int(cp, 16) for cp in path.stem.split("-")]): path
            for path in (repo / "assets/svg").glob("*.svg")
        }

        # nanoemojiは、ファイル名のemoji_u<符号位置>_<符号位置>.svgを、その並びの絵として読む。
        staged = work / "staged"
        staged.mkdir()
        names: set[str] = set()

        def stage(codepoints: list[int], source: Path) -> None:
            name = "emoji_u" + "_".join(f"{cp:04x}" for cp in codepoints)
            if name in names:
                return
            names.add(name)
            shutil.copyfile(source, staged / f"{name}.svg")

        for path in svgs.values():
            stage([int(cp, 16) for cp in path.stem.split("-")], path)
        for codepoints, path in svgs.items():
            stage(list(codepoints), path)
        missing = 0
        for codepoints in emoji_sequences():
            source = svgs.get(without_vs16(codepoints))
            if source is None:
                missing += 1
                continue
            stage(codepoints, source)
            stage(list(without_vs16(codepoints)), source)
        if missing:
            # twemojiの版がUnicodeの版に追いついていないと、絵のない並びが出る。その並びはAppleの絵文字で描かれる。
            print(f"twemojiに絵のない並び: {missing}件", file=sys.stderr)

        build = work / "build"
        subprocess.run(
            ["nanoemoji", "--color_format", "glyf_colr_0", "--family", "Twemoji", "--output_file", "Twemoji.ttf",
             "--build_dir", str(build), *sorted(str(path) for path in staged.glob("*.svg"))],
            check=True,
        )
        shutil.copyfile(build / "Twemoji.ttf", OUTPUT)
    print(f"{len(names)}件の並びを書き出しました: {OUTPUT}")


if __name__ == "__main__":
    main()
