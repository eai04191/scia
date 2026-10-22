# /// script
# requires-python = ">=3.12"
# ///
"""投稿欄の絵文字のシートに並べる、Unicodeの絵文字の一覧を作る。

並びとまとまりは、Unicodeの絵文字の一覧（emoji-test.txt）の順にする。iOSの絵文字キーボードとほぼ同じ並び。
検索に使う名前と言葉は、CLDRの絵文字の注釈（日本語と英語）から取る。本体の注釈にない並び（肌の色や旗など）は、派生の注釈から取る。
注釈はU+FE0Fを除いた並びで引く。どちらにもなければ、emoji-test.txtの英語の名前だけを使う。

入れないもの:
- 完全な形でない並び（minimally-qualified、unqualified）。同じ絵文字の完全な形が別にあるため
- 肌の色を付けた並び。肌の色を選ぶ仕組みはまだないため、肌の色のない形だけを並べる
- 部品（Component）のまとまり。肌の色や髪型の部品だけでは絵文字にならないため

twemojiの書体（Tools/build-twemoji-font.py）と同じUnicodeの版にする。

使い方: uv run Tools/build-emoji-data.py
"""

import json
import urllib.request
from pathlib import Path

UNICODE_EMOJI_VERSION = "17.0"
CLDR_VERSION = "48.2.3"
OUTPUT = Path("Packages/SciaCore/Sources/SciaCore/Compose/Resources/standard-emoji.json")

# emoji-test.txtのまとまりの名前を、iOSの絵文字キーボードに近い日本語の名前にする。
GROUP_TITLES = {
    "Smileys & Emotion": "顔と感情",
    "People & Body": "人と体",
    "Animals & Nature": "動物と自然",
    "Food & Drink": "食べ物と飲み物",
    "Travel & Places": "旅行と場所",
    "Activities": "活動",
    "Objects": "物",
    "Symbols": "記号",
    "Flags": "旗",
}
SKIN_TONES = {chr(cp) for cp in range(0x1F3FB, 0x1F400)}
VS16 = "️"


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url) as response:
        return response.read()


def annotations(locale: str) -> dict[str, dict]:
    base = f"https://raw.githubusercontent.com/unicode-org/cldr-json/{CLDR_VERSION}/cldr-json"
    plain = json.loads(fetch(f"{base}/cldr-annotations-full/annotations/{locale}/annotations.json"))
    derived = json.loads(fetch(f"{base}/cldr-annotations-derived-full/annotationsDerived/{locale}/annotations.json"))
    merged = dict(derived["annotationsDerived"]["annotations"])
    merged.update(plain["annotations"]["annotations"])
    return merged


def lookup(table: dict[str, dict], emoji: str) -> dict | None:
    return table.get(emoji) or table.get(emoji.replace(VS16, ""))


def main() -> None:
    ja = annotations("ja")
    en = annotations("en")
    text = fetch(f"https://www.unicode.org/Public/{UNICODE_EMOJI_VERSION}.0/emoji/emoji-test.txt").decode()
    groups: list[dict] = []
    current: dict | None = None
    missing = 0
    for line in text.splitlines():
        if line.startswith("# group: "):
            name = line.removeprefix("# group: ").strip()
            title = GROUP_TITLES.get(name)
            current = {"title": title, "emojis": []} if title else None
            if current:
                groups.append(current)
            continue
        if current is None or not line or line.startswith("#"):
            continue
        fields, _, comment = line.partition("#")
        codepoints, _, status = fields.partition(";")
        if status.strip() != "fully-qualified":
            continue
        emoji = "".join(chr(int(cp, 16)) for cp in codepoints.split())
        if any(ch in SKIN_TONES for ch in emoji):
            continue
        # コメントは「😀 E1.0 grinning face」の形。
        _, version, english_name = comment.strip().split(" ", 2)
        ja_entry = lookup(ja, emoji)
        en_entry = lookup(en, emoji)
        if ja_entry is None:
            missing += 1
        name = (ja_entry or {}).get("tts", [english_name])[0]
        keywords = sorted(set((ja_entry or {}).get("default", [])) | set((en_entry or {}).get("default", [])) | {english_name})
        current["emojis"].append({"e": emoji, "n": name, "k": keywords, "v": version.removeprefix("E")})
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps({"unicode": UNICODE_EMOJI_VERSION, "cldr": CLDR_VERSION, "groups": groups}, ensure_ascii=False, separators=(",", ":")) + "\n")
    count = sum(len(g["emojis"]) for g in groups)
    print(f"{OUTPUT}: {count} emoji in {len(groups)} groups, {missing} without Japanese annotations")


if __name__ == "__main__":
    main()
