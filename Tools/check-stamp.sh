#!/bin/bash
# `make check`が通った中身を覚え、ローカルのmainに入れてよいかを、Tools/git-hooks/reference-transactionが調べられるようにする。
# 覚えるのはcommitではなくtree（ファイルの中身の組）。commitする前の作業ツリーで通しても、commitしたtreeが同じなら、通ったものとして扱える。
# 作業ツリーのtreeは、indexの写しにgit add -Aして作るので、まだcommitしていない変更も含む。.gitignoreにあるもの（生成するxcodeprojやDerivedData）は含めない。
# 覚えたtreeは、worktreeどうしで共有する.gitの共通ディレクトリのscia-check/に、treeのハッシュを名前にした空のファイルで置く。hookも同じ場所を読む。
# 使い方:
#   Tools/check-stamp.sh tree           今の作業ツリーのtreeを出す
#   Tools/check-stamp.sh record <tree>  今の作業ツリーが<tree>のままなら、通ったものとして覚える
set -euo pipefail

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
        tree=${2:?treeを渡す}
        # 走らせている間にファイルを書き換えると、確かめた中身と覚える中身がずれるので、覚えない
        if [[ "$(worktree_tree)" != "$tree" ]]; then
            echo "error: make checkの途中で作業ツリーが変わったので、通ったものとして覚えません。もう一度make checkを走らせてください" >&2
            exit 1
        fi
        dir="$(git rev-parse --git-common-dir)/scia-check"
        mkdir -p "$dir"
        touch "$dir/$tree"
        echo "make checkが通った中身（tree ${tree:0:12}）を覚えました。この中身のcommitはmainに入れられます"
        ;;
    *)
        echo "使い方: Tools/check-stamp.sh tree | record <tree>" >&2
        exit 1
        ;;
esac
