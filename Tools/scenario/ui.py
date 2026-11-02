# `axe describe-ui`の出力（JSON）を標準入力で受け取り、要素があるかを終了コードで返す。setup.shが画面を待つのに使う。
# 使い方:
#   axe describe-ui --udid <UDID> | python3 -I ui.py has <AXLabelかAXValue> [<type>]
#     木のどこかに、AXLabelかAXValueが一致する（typeを渡せば種類も一致する）要素があれば0、なければ1。入力欄のプレースホルダーはAXValueに入る
#   axe describe-ui --udid <UDID> | python3 -I ui.py contains <文字列>
#     AXLabelにその文字列を含む要素があれば0、なければ1。投稿の行のように、時刻などが混ざるラベルに使う
#   axe describe-ui --point <x,y> --udid <UDID> | python3 -I ui.py label
#     その位置の要素のAXLabelを出す
import json
import sys


def nodes(value):
    if isinstance(value, list):
        for item in value:
            yield from nodes(item)
    elif isinstance(value, dict):
        yield value
        yield from nodes(value.get("children", []))


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 1
    if sys.argv[1] == "has":
        label = sys.argv[2]
        kind = sys.argv[3] if len(sys.argv) > 3 else None
        found = any(label in (n.get("AXLabel"), n.get("AXValue")) and (kind is None or n.get("type") == kind) for n in nodes(data))
        return 0 if found else 1
    if sys.argv[1] == "contains":
        return 0 if any(sys.argv[2] in (n.get("AXLabel") or "") for n in nodes(data)) else 1
    if sys.argv[1] == "label":
        print(next(nodes(data), {}).get("AXLabel") or "")
        return 0
    return 2


sys.exit(main())
