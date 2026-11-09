#!/bin/bash
# 1人分を走らせる。リセットしてからSciaを起動し、何も知らないエージェントを役のとおりに「初めて使う人」として触らせ、報告を残す。
# エージェントは、リポジトリの外の実行ごとのフォルダーで、CLAUDE.md、メモリ、設定、MCPを読まずに起動する（--setting-sources ""と--strict-mcp-config）。
# 使えるのは、AXe、Sciaの起動し直し、撮った画像を見るReadだけで、ほかのコマンドは聞かずに断る（--permission-mode dontAsk）。
# 報告は$SCENARIO_RUNS/<日時>-<役>/report.md、スクリーンショットはその中のshots/、送ったコマンドはcommands.txtに残る。終わったら端末を止める。
# 使い方: Tools/scenario/run.sh <Scia.appのパス> <役>（役はpersonas/の、common以外のファイルの名前）
set -euo pipefail
source "$(dirname "$0")/common.sh"

app="${1:?使い方: Tools/scenario/run.sh <Scia.appのパス> <役>}"
persona="${2:?使い方: Tools/scenario/run.sh <Scia.appのパス> <役>}"
persona_file="$SCENARIO_DIR/personas/$persona.md"
[ "$persona" != common ] && [ -f "$persona_file" ] || fail "役がない: ${persona}（personas/にあるもの: $(cd "$SCENARIO_DIR/personas" && ls | sed 's/\.md$//' | grep -vx common | tr '\n' ' ')）"
command -v claude >/dev/null || fail "claude が見つからない"

"$SCENARIO_DIR/reset.sh" "$app"
udid="$(device_udid)"
# エージェントや結果の読み取りが途中で失敗しても、端末を起動したまま残さない
trap 'shutdown_device "$udid"' EXIT
run_dir="$SCENARIO_RUNS/$(date +%Y%m%d-%H%M%S)-$persona"
mkdir -p "$run_dir/shots"
sed -e "s|{{UDID}}|$udid|g" -e "s|{{SHOTS}}|$run_dir/shots|g" "$SCENARIO_DIR/personas/common.md" > "$run_dir/prompt.md"
printf '\n' >> "$run_dir/prompt.md"
cat "$persona_file" >> "$run_dir/prompt.md"

xcrun simctl launch "$udid" "$SCIA_BUNDLE_ID" >/dev/null
log "役「${persona}」で触らせる: $run_dir"
status=0
(
    cd "$run_dir"
    claude -p \
        --setting-sources "" \
        --strict-mcp-config \
        --no-session-persistence \
        --tools Bash Read \
        --allowedTools "Bash(axe *)" "Bash(xcrun simctl launch $udid net.mizle.scia)" Read \
        --permission-mode dontAsk \
        --output-format stream-json \
        --verbose \
        < prompt.md > events.jsonl
) || status=$?
# エージェントが送ったコマンドを、送った順にcommands.txtに残す。batchで続けて送ったかなど、報告に書かれない操作のしかたを確かめるため
python3 -I -c '
import json, sys
with open(sys.argv[1]) as events, open(sys.argv[2], "w") as commands, open(sys.argv[3], "w") as result:
    for line in events:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "result":
            json.dump(event, result)
        message = event.get("message")
        if not isinstance(message, dict) or not isinstance(message.get("content"), list):
            continue
        for block in message["content"]:
            if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") == "Bash":
                commands.write(block.get("input", {}).get("command", "").replace("\n", " ") + "\n")
' "$run_dir/events.jsonl" "$run_dir/commands.txt" "$run_dir/result.json" || status=1
# 終了コードが0でも、JSONでエラーと返ることがある。どちらかが失敗なら、報告を残せた分は残してから失敗で終わる
python3 -I -c '
import json, sys
try:
    result = json.load(open(sys.argv[1]))
except (OSError, json.JSONDecodeError) as error:
    print("scenario: エージェントの結果を読めない: %s" % error, file=sys.stderr)
    sys.exit(1)
open(sys.argv[2], "w").write(result.get("result") or "")
print("scenario: 手数 %s、%s秒" % (result.get("num_turns"), round(result.get("duration_ms", 0) / 1000)), file=sys.stderr)
if result.get("is_error") or result.get("subtype") != "success":
    print("scenario: エージェントがエラーで終わった: %s" % result.get("subtype"), file=sys.stderr)
    sys.exit(1)
' "$run_dir/result.json" "$run_dir/report.md" || status=1
[ "$status" -eq 0 ] || fail "最後まで走らなかった。$run_dir/result.json を見る"
log "報告: $run_dir/report.md"
