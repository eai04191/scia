#!/usr/bin/env python3
"""借りていない端末へ命令を送るのを、実行の前に止める。Claude CodeのPreToolUseのhook（.claude/settings.json）から呼ぶ。

貸し借り（Tools/sim.sh acquire）は約束事で、端末に鍵は掛からない。`xcrun simctl`とシミュレーターのツールは、
名前を渡せばどの端末にも届くので、次の2つを止める。

- 端末に命令を送る`xcrun simctl`を、直接呼ぶこと。貸し借りを確かめる関門（`Tools/sim.sh ctl '<端末>' <操作> ...`）を通させる。
  コマンドのどの引数が端末かを、ここでは読み解かない。操作ごとにオプションと端末の位置が違い、読み違えるとすり抜けるため。
- シミュレーターのツールで、このworktreeが借りていない貸し借りの端末（`Scia 1`〜`Scia 4`、`Scia iPad 1`、`Scia Duo`など。`Tools/sim.sh`の`pool`が決める）を指すこと。

標準入力にhookの入力のJSONを受け取り、止めるときは理由を標準エラーに書いて終了コード2で終わる。
`--self-test`で、コマンドから`simctl`の実行を読み取る部分だけを確かめる。
"""

import json
import os
import re
import shlex
import subprocess
import sys

SIMULATOR_TOOL = "mcp__Claude_Code_iOS_Simulator__control"
# 端末を変えないsimctlの操作。借りる前に状態を調べるのに使うので、直接呼んでよい。
READ_ONLY = {"list", "get_app_container", "listapps", "appinfo", "getenv", "help"}
# 端末を省いても動く、シミュレーターのツールの操作。
TOOL_ACTIONS_WITHOUT_DEVICE = {"detach"}


# ほかのコマンドを引数に取って実行する語。後ろに続くコマンドを見る。
WRAPPERS = {"env", "sudo", "time", "nohup", "command", "exec", "xargs", "caffeinate"}
# 文字列をコマンドとして実行するシェル。
SHELLS = {"bash", "sh", "zsh"}


def direct_simctl_operations(command):
    """コマンドが直接実行する`simctl`の操作のうち、端末に命令を送るもの。読み取れないコマンドは"?"を返す。

    実行される位置にある`simctl`だけを数える。`rg simctl`や`echo 'xcrun simctl ...'`のような、検索の語や表示する文字列は数えない。
    `bash -c "..."`や`eval`に渡した文字列は、コマンドとして実行されるので中を読む。
    """
    # 行の継続をつなぎ、改行はコマンドの区切りとして読む。
    text = command.replace("\\\n", " ").replace("\n", " ; ")
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        # 引用符が閉じていないなど、分けられないコマンド。
        return ["?"] if "simctl" in command else []
    operations, segment = [], []
    for token in tokens + [";"]:
        # 区切りの記号は、`);`や`&&`のように、続けて書くと1つの語になる。
        if re.fullmatch(r"[();<>|&]+", token):
            operations += segment_operations(segment)
            segment = []
        else:
            segment.append(token)
    return operations


def segment_operations(words):
    """区切りのない1つのコマンド（語の並び）が実行する`simctl`の操作。"""
    # 先頭の`VAR=値`と、ほかのコマンドを実行する語を読み飛ばして、実行されるコマンドの語を探す。
    while words and (re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", words[0]) or os.path.basename(words[0]) in WRAPPERS or (words[0].startswith("-") and len(words) > 1)):
        words = words[1:]
    if not words:
        return []
    name = os.path.basename(words[0])
    if name in SHELLS:
        # `-c`の次の語がコマンドの文字列。`-lc`のようにまとめて書いたものも拾う。
        for index, word in enumerate(words[1:], start=1):
            if re.fullmatch(r"-[a-zA-Z]*c[a-zA-Z]*", word) and index + 1 < len(words):
                return direct_simctl_operations(words[index + 1])
        return []
    if name == "eval":
        return direct_simctl_operations(" ".join(words[1:]))
    if name == "xcrun":
        # xcrun自身のオプション（`--sdk iphonesimulator`、`-r`など）の後ろにあるsimctlを探す。
        for index, word in enumerate(words[1:], start=1):
            if os.path.basename(word) == "simctl":
                words = words[index:]
                break
        else:
            return []
    elif name != "simctl":
        return []
    rest = words[1:]
    # `simctl --set <場所> <操作>`のような、操作の前のオプションを読み飛ばす。
    while rest and rest[0].startswith("-"):
        rest = rest[2:] if rest[0] == "--set" else rest[1:]
    return [rest[0]] if rest and rest[0] not in READ_ONLY else []


def tool_refusal(tool_input, top):
    """シミュレーターのツールの呼び出しを止める理由。送ってよければNone。"""
    if tool_input.get("action") in TOOL_ACTIONS_WITHOUT_DEVICE:
        return None
    device = tool_input.get("device") or tool_input.get("udid")
    if not device:
        return "deviceがない。省くと、ほかのスレッドが使っている端末を操作することがある。借りた端末の名前を渡す"
    if re.fullmatch(r"[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", device):
        return "deviceは、UDIDではなく名前で渡す。貸し借りする端末かを名前で確かめるため"
    leased = subprocess.run([os.path.join(top, "Tools", "sim.sh"), "leased", device], capture_output=True, text=True, cwd=top)
    if leased.returncode == 0:
        return None
    return (leased.stderr or leased.stdout).strip() or f"{device}を借りていない"


def repository_top(cwd):
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, cwd=cwd or None)
    if top.returncode != 0:
        return None
    path = top.stdout.strip()
    return path if os.path.exists(os.path.join(path, "Tools", "sim.sh")) else None


def main():
    payload = json.load(sys.stdin)
    tool, tool_input = payload.get("tool_name"), payload.get("tool_input") or {}
    if tool == "Bash":
        command = tool_input.get("command", "")
        if "simctl" not in command:
            return 0
        operations = direct_simctl_operations(command)
        if not operations or repository_top(payload.get("cwd")) is None:
            # このリポジトリの外には、貸し借りの決まりがない。
            return 0
        print(f"xcrun simctl {operations[0]}の直接の呼び出しを止めた。端末に命令を送るsimctlは、貸し借りを確かめる"
              f"Tools/sim.sh ctl '<借りた端末>' {operations[0]} <引数...>で送る。"
              "Tools/sim.sh acquireの出力の最後の行で、借りた端末を確かめてから、次のコマンドで送る。", file=sys.stderr)
        return 2
    if tool == SIMULATOR_TOOL:
        top = repository_top(payload.get("cwd"))
        if top is None:
            return 0
        reason = tool_refusal(tool_input, top)
        if reason is None:
            return 0
        print(f"シミュレーターのツールの呼び出しを止めた（{tool_input.get('action', '?')}）: {reason}。"
              "Tools/sim.sh acquireの出力の最後の行で、借りた端末を確かめてから、その名前で送り直す。", file=sys.stderr)
        return 2
    return 0


def self_test():
    cases = {
        "xcrun simctl openurl 'Scia 1' 'scia://settings'": ["openurl"],
        "Tools/sim.sh acquire | tail -1 && xcrun simctl install 'Scia 2' App.app && xcrun simctl launch \"Scia 2\" net.mizle.scia": ["install", "launch"],
        "C=$(xcrun simctl get_app_container 'Scia 1' net.mizle.scia data); xcrun simctl spawn 'Scia 1' defaults read x": ["spawn"],
        "C=$(xcrun simctl get_app_container 'Scia 1' net.mizle.scia data) && Tools/sim.sh ctl 'Scia 1' spawn defaults read \"$C/x\"": [],
        "xcrun simctl list devices | grep Scia": [],
        "xcrun simctl delete 'Scia 2'": ["delete"],
        "xcrun simctl shutdown all": ["shutdown"],
        "xcrun simctl launch -a arm64 'Scia 2' net.mizle.scia": ["launch"],
        "xcrun simctl \\\n  install 'Scia 2' App.app": ["install"],
        "bash -c \"xcrun simctl install 'Scia 2' App.app\"": ["install"],
        "xcrun simctl list\nxcrun simctl boot 'Scia 3'": ["boot"],
        "/usr/bin/simctl boot \"$SIM\"": ["boot"],
        "Tools/sim.sh ctl 'Scia 2' openurl 'scia://settings'": [],
        "xcrun --sdk iphonesimulator simctl install 'Scia 2' App.app": ["install"],
        "xcrun -r simctl launch 'Scia 2' net.mizle.scia": ["launch"],
        "SIMCTL_CHILD_X=1 xcrun simctl launch 'Scia 2' net.mizle.scia": ["launch"],
        "echo x | xargs xcrun simctl openurl 'Scia 2'": ["openurl"],
        "bash -lc \"xcrun simctl boot 'Scia 2'\"": ["boot"],
        "eval \"xcrun simctl boot 'Scia 2'\"": ["boot"],
        "rg -n 'xcrun simctl launch' AGENTS.md": [],
        "echo \"xcrun simctl launch 'Scia 2'\"": [],
        "(xcrun simctl boot 'Scia 2'); echo done": ["boot"],
        "xcrun simctl list > /tmp/out; xcrun simctl boot 'Scia 2' 2>&1 | tail -1": ["boot"],
        "rg -n simctl Tools": [],
        "echo simctl": [],
        "git log --grep simctl": [],
    }
    failed = False
    for command, expected in cases.items():
        actual = direct_simctl_operations(command)
        if actual != expected:
            failed = True
            print(f"NG: {command}\n  期待: {expected}\n  実際: {actual}")
    print("self-test " + ("失敗" if failed else "OK"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(self_test() if sys.argv[1:] == ["--self-test"] else main())
