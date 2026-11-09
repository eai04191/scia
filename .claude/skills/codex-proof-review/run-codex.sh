#!/bin/bash
# 使い捨ての複製の中でCodexのレビューを走らせる。コマンドからは、複製への書き込みとテストの実行、外への通信はできるが、ホームの資格情報とKeychainと環境変数の秘密は読めない。
# 使い方: run-codex.sh <複製> <指示のファイル> <stdoutの保存先> <stderrの保存先>
set -euo pipefail

copy="${1:?複製を渡す}"
prompt="${2:?指示のファイルを渡す}"
out="${3:?stdoutの保存先を渡す}"
log="${4:?stderrの保存先を渡す}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Codexは自分自身をsandboxの中で起動する。本体はホームの中にあり、ホームを読めないと起動できないので、外へコピーする。
codex_binary="$(realpath "$(command -v codex)")"
release="$(dirname "$(dirname "$codex_binary")")"
cp -cR "$release" "$work/codex-release"

mkdir "$work/home"
user_cache="$(getconf DARWIN_USER_CACHE_DIR)"
user_cache="${user_cache%/}"
shared_objects="$(cat "$copy/.git/objects/info/alternates")"

filesystem="\":root\"=\"deny\",\":minimal\"=\"read\",\":tmpdir\"=\"write\",\":slash_tmp\"=\"write\""
filesystem+=",\"$user_cache\"=\"write\",\"$shared_objects\"=\"read\",\"/Applications/Xcode.app\"=\"read\""

(
    cd "$copy"
    "$work/codex-release/bin/codex" review \
        -c "permissions.proof={extends=\":workspace\",filesystem={$filesystem},network={enabled=true}}" \
        -c 'default_permissions="proof"' \
        -c 'shell_environment_policy.inherit="core"' \
        -c "shell_environment_policy.set.HOME=\"$work/home\"" \
        -c 'model="gpt-6.1-sol"' \
        -c 'model_reasoning_effort="high"' \
        -c 'service_tier="priority"' \
        -
) <"$prompt" >"$out" 2>"$log"
