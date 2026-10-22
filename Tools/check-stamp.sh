#!/bin/bash
# `make check`と`make test`が通った中身を覚え、ローカルのmainに入れてよいかを調べる。Tools/git-hooks/reference-transactionもこれで調べる。
# 覚えるのはcommitではなくtree（ファイルの中身の組）。commitする前の作業ツリーで通しても、commitしたtreeが同じなら、通ったものとして扱える。
# 作業ツリーのtreeは、indexの写しにgit add -Aして作るので、まだcommitしていない変更も含む。.gitignoreにあるもの（生成するxcodeprojやDerivedData）は含めない。
# 覚えたtreeは、worktreeどうしで共有する.gitの共通ディレクトリのscia-check/<check|test>/に、treeのハッシュを名前にした空のファイルで置く。
# 使い方:
#   Tools/check-stamp.sh tree                        今の作業ツリーのtreeを出す
#   Tools/check-stamp.sh record <check|test> <tree>  今の作業ツリーが<tree>のままなら、通ったものとして覚える
#   Tools/check-stamp.sh missing <commit>            <commit>の中身でまだ通っていないもの（make check、make test）を1行ずつ出す
set -euo pipefail

KINDS="check test"

stamp_dir() {
    echo "$(git rev-parse --git-common-dir)/scia-check/$1"
}

worktree_tree() {
    local index tree
    index=$(mktemp)
    cp "$(git rev-parse --git-path index)" "$index"
    GIT_INDEX_FILE=$index git add -A
    tree=$(GIT_INDEX_FILE=$index git write-tree)
    rm -f "$index"
    echo "$tree"
}

case "${1:-}" in
    tree)
        worktree_tree
        ;;
    record)
        kind=${2:?checkかtestを渡す}
        tree=${3:?treeを渡す}
        [[ " $KINDS " == *" $kind "* ]] || { echo "error: checkかtestを渡してください: $kind" >&2; exit 1; }
        # 走らせている間にファイルを書き換えると、確かめた中身と覚える中身がずれるので、覚えない
        if [[ "$(worktree_tree)" != "$tree" ]]; then
            echo "error: make $kindの途中で作業ツリーが変わったので、通ったものとして覚えません。もう一度make $kindを走らせてください" >&2
            exit 1
        fi
        mkdir -p "$(stamp_dir "$kind")"
        touch "$(stamp_dir "$kind")/$tree"
        echo "make $kindが通った中身（tree ${tree:0:12}）を覚えました"
        ;;
    missing)
        tree=$(git rev-parse "${2:?commitを渡す}^{tree}")
        for kind in $KINDS; do
            [[ -e "$(stamp_dir "$kind")/$tree" ]] || echo "make $kind"
        done
        ;;
    *)
        echo "使い方: Tools/check-stamp.sh tree | record <check|test> <tree> | missing <commit>" >&2
        exit 1
        ;;
esac
