# /// script
# requires-python = ">=3.12"
# ///
"""投稿欄の絵文字のシートに並べる、Unicodeの絵文字のリストを作る。

並びとまとまりは、Unicodeの絵文字のリスト（emoji-test.txt）の順にする。iOSの絵文字キーボードとほぼ同じ並び。
検索に使う名前と言葉は、CLDRの絵文字の注釈（日本語と英語）から取る。本体の注釈にない並び（肌の色や旗など）は、派生の注釈から取る。
注釈はU+FE0Fを除いた並びで引く。どちらにもなければ、emoji-test.txtの英語の名前だけを使う。
英語の名前（emoji-test.txtの名前）は、補完で名前と一致するものを先に並べるために、言葉とは別にも持つ。
補完で`:+1`や`:thumbsup`のように打てるよう、GitHubやSlackで使われる短縮名をgemojiから取る。

入れないもの:
- 完全な形でない並び（minimally-qualified、unqualified）。同じ絵文字の完全な形が別にあるため
- 肌の色を付けた並びは、1つの絵文字としては並べない。肌の色のない形の`t`に、変化形として持たせる（下の「肌の色」）
- 部品（Component）のまとまり。肌の色や髪型の部品だけでは絵文字にならないため

肌の色:
- 肌の色を変えられる絵文字は、`t`に肌の色を付けた並びを持つ。肌の色は明るいほうから5つ（U+1F3FB〜U+1F3FF）
- 1人の絵文字は5つ。2人の絵文字（握手、手をつなぐ人など）は25個で、1人目の色を行、2人目の色を列にして、行ごとに並べる（`t[1人目 * 5 + 2人目]`）
- どの並びがどの絵文字の変化形かは、emoji-test.txtの名前で決める。変化形の名前は「元の名前: 肌の色[, 肌の色]」の形で、
  2人の色が違う並びは元の絵文字と別の文字で組まれることがある（握手の🤝に対する🫱🏻‍🫲🏼）ため、文字からは決められない
- 「kiss」と「couple with heart」は、2人の色が違う並びだけ「kiss: person, person」の名前になっているので、元の名前に読み替える

twemojiの書体（Tools/build-twemoji-font.py）と同じUnicodeの版にする。

使い方: uv run Tools/build-emoji-data.py
"""

import json
import urllib.request
from pathlib import Path

UNICODE_EMOJI_VERSION = "17.0"
CLDR_VERSION = "48.2.3"
GEMOJI_VERSION = "v4.1.0"
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
SKIN_TONE_NAMES = ["light skin tone", "medium-light skin tone", "medium skin tone", "medium-dark skin tone", "dark skin tone"]
# 2人の色が違う並びだけ、名前に「person, person」が付く絵文字。
PAIR_BASE_NAMES = {"kiss: person, person": "kiss", "couple with heart: person, person": "couple with heart"}
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


def shortcodes() -> dict[str, list[str]]:
    entries = json.loads(fetch(f"https://raw.githubusercontent.com/github/gemoji/{GEMOJI_VERSION}/db/emoji.json"))
    return {entry["emoji"].replace(VS16, ""): entry["aliases"] for entry in entries}


def skin_tone_variants(text: str) -> dict[str, list[str]]:
    """肌の色のない絵文字の英語の名前から、肌の色を付けた並びのリストを引く。1人の絵文字は5つ、2人の絵文字は25個。"""
    found: dict[str, dict[tuple[int, ...], str]] = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        fields, _, comment = line.partition("#")
        codepoints, _, status = fields.partition(";")
        if status.strip() != "fully-qualified":
            continue
        emoji = "".join(chr(int(cp, 16)) for cp in codepoints.split())
        if not any(ch in SKIN_TONES for ch in emoji):
            continue
        _, _, name = comment.strip().split(" ", 2)
        head, _, rest = name.partition(": ")
        parts = rest.split(", ")
        tones = tuple(SKIN_TONE_NAMES.index(part) for part in parts if part in SKIN_TONE_NAMES)
        others = [part for part in parts if part not in SKIN_TONE_NAMES]
        base = head + (": " + ", ".join(others) if others else "")
        found.setdefault(PAIR_BASE_NAMES.get(base, base), {})[tones] = emoji
    variants: dict[str, list[str]] = {}
    for base, by_tones in found.items():
        if all(len(tones) == 1 for tones in by_tones):
            variants[base] = [by_tones[(tone,)] for tone in range(5)]
        else:
            # 2人とも同じ色の並びは、色を1つだけ付けた名前で載っている。
            variants[base] = [by_tones[(first,)] if first == second else by_tones[(first, second)] for first in range(5) for second in range(5)]
    return variants


def main() -> None:
    ja = annotations("ja")
    en = annotations("en")
    aliases = shortcodes()
    text = fetch(f"https://www.unicode.org/Public/{UNICODE_EMOJI_VERSION}.0/emoji/emoji-test.txt").decode()
    variants = skin_tone_variants(text)
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
        entry = {"e": emoji, "n": name, "en": english_name, "k": keywords, "v": version.removeprefix("E")}
        if emoji_aliases := aliases.get(emoji.replace(VS16, "")):
            entry["s"] = emoji_aliases
        if tones := variants.pop(english_name, None):
            entry["t"] = tones
        current["emojis"].append(entry)
    if variants:
        raise SystemExit(f"肌の色の変化形の元の絵文字が見つからない: {sorted(variants)}")
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps({"unicode": UNICODE_EMOJI_VERSION, "cldr": CLDR_VERSION, "gemoji": GEMOJI_VERSION, "groups": groups}, ensure_ascii=False, separators=(",", ":")) + "\n")
    count = sum(len(g["emojis"]) for g in groups)
    print(f"{OUTPUT}: {count} emoji in {len(groups)} groups, {missing} without Japanese annotations")


if __name__ == "__main__":
    main()
