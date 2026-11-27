#!/bin/bash
# `make check`と`make test`が通った中身を記録し、ローカルのmainに入れてよいかを調べる。Tools/git-hooks/reference-transactionもこれで調べる。
# 記録するのはcommitではなくtree（ファイルの中身の組）。commitする前の作業ツリーで通しても、commitしたtreeが同じなら、通ったものとして扱える。
# 作業ツリーのtreeは、indexのコピーにgit add -Aして作るので、まだcommitしていない変更も含む。.gitignoreにあるもの（生成するxcodeprojやDerivedData）は含めない。
# 記録したtreeは、worktreeどうしで共有する.gitの共通ディレクトリのscia-check/<check|test>/に、treeのハッシュを名前にした空のファイルで置く。
# 使い方:
#   Tools/check-stamp.sh tree                        今の作業ツリーのtreeを出す
#   Tools/check-stamp.sh record <check|test> <tree>  今の作業ツリーが<tree>のままなら、通ったものとして記録する
#   Tools/check-stamp.sh record-remote <check|test> <tree>  別のMacが<tree>の中身で走らせて通ったものとして記録する。手元の作業ツリーとは比べない
#   Tools/check-stamp.sh missing <commit> [<base>]   <commit>の中身でまだ通っていないもの（make check、make test）を1行ずつ出す
# <base>を渡すと、<base>の中身で通っていて、<commit>との違いがMarkdown（*.md）とサーバーのリスト（known-servers.txt）だけなら、通ったものとして扱い、<commit>の中身も記録する。
# 追跡しているMarkdownは、ビルドにもテストにも入らず、lintで見るのは造語の検査（Tools/check-coined-words.py）と読点の検査（Tools/check-pause-comma.py）だけなので、引き継ぐ前に、変わったMarkdownをその2つにかける。
# .agents/skills/にはシェルスクリプトもあるので、ディレクトリではなく拡張子で見る。
# サーバーのリストは、GitHub Actionsが毎週作り直してPRにするデータで、読むテストはServerSuggestionsTestsのloadsTheBundledListだけ。その条件（1000件を超える、mastodon.socialがある、空の行がない）は、Tools/update-known-servers.shが書き出す前に確かめる。
# 手でリストを書き換えたときは、この条件を誰も確かめないまま通ったものとして扱う。リストを手で直すことはなく、確かめるためにmake testを走らせると、除外する意味がなくなるので、そこまでは見ない。
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

# renameを1つの変更として扱うと、.swiftから.mdへの名前の変更が.mdの変更だけに見えるので、--no-renamesで消したファイルも比べる
# git diff --quietは、違いがなければ0、あれば1を返す。それ以外は調べられなかったので、取り違えないよう失敗させる
only_unchecked_files_differ() {
    local status=0
    git diff --quiet --no-renames "$1" "$2" -- . ':(exclude)*.md' \
        ':(exclude)Packages/SciaCore/Sources/SciaCore/Auth/Resources/known-servers.txt' || status=$?
    case $status in
        0) return 0 ;;
        1) return 1 ;;
        *)
            echo "error: $1と$2の違いを調べられませんでした" >&2
            exit "$status"
            ;;
    esac
}

# <base>から<commit>で足したり変えたりしたMarkdownを、<commit>の中身で造語と読点の検査にかける。当たれば、両方の検査の出力を出して1を返す
markdown_passes_lint() {
    local files=() file
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(git diff --name-only -z --no-renames --diff-filter=AM "$1" "$2" -- '*.md')
    [[ ${#files[@]} -eq 0 ]] && return 0
    local status=0
    python3 "$(dirname "$0")/check-coined-words.py" --at "$2" "${files[@]}" >&2 || status=1
    python3 "$(dirname "$0")/check-pause-comma.py" --at "$2" "${files[@]}" >&2 || status=1
    return "$status"
}

case "${1:-}" in
    tree)
        worktree_tree
        ;;
    record)
        kind=${2:?checkかtestを渡す}
        tree=${3:?treeを渡す}
        [[ " $KINDS " == *" $kind "* ]] || { echo "error: checkかtestを渡してください: $kind" >&2; exit 1; }
        # 走らせている間にファイルを書き換えると、確かめた中身と記録する中身がずれるので、記録しない
        if [[ "$(worktree_tree)" != "$tree" ]]; then
            echo "error: make ${kind}の途中で作業ツリーが変わったので、通ったものとして記録しません。もう一度make ${kind}を走らせてください" >&2
            exit 1
        fi
        mkdir -p "$(stamp_dir "$kind")"
        touch "$(stamp_dir "$kind")/$tree"
        echo "make ${kind}が通った中身（tree ${tree:0:12}）を記録しました"
        ;;
    record-remote)
        kind=${2:?checkかtestを渡す}
        tree=${3:?treeを渡す}
        [[ " $KINDS " == *" $kind "* ]] || { echo "error: checkかtestを渡してください: $kind" >&2; exit 1; }
        mkdir -p "$(stamp_dir "$kind")"
        touch "$(stamp_dir "$kind")/$tree"
        echo "別のMacでmake ${kind}が通った中身（tree ${tree:0:12}）を記録しました"
        ;;
    missing)
        commit=${2:?commitを渡す}
        base=${3:-}
        tree=$(git rev-parse "$commit^{tree}")
        base_tree=
        [[ -n "$base" ]] && base_tree=$(git rev-parse "$base^{tree}")
        # Markdownの検査は、checkとtestのどちらで引き継ぐときも同じ結果なので、1回だけ走らせる
        markdown_checked=
        for kind in $KINDS; do
            [[ -e "$(stamp_dir "$kind")/$tree" ]] && continue
            inherits=no
            if [[ -n "$base_tree" && -e "$(stamp_dir "$kind")/$base_tree" ]] && only_unchecked_files_differ "$base" "$commit"; then
                if [[ -z "$markdown_checked" ]]; then
                    markdown_checked=no
                    markdown_passes_lint "$base" "$commit" && markdown_checked=yes
                fi
                inherits=$markdown_checked
            fi
            if [[ "$inherits" == yes ]]; then
                # 次にこの中身と比べるときにも引き継げるよう、記録しておく
                touch "$(stamp_dir "$kind")/$tree"
                continue
            fi
            echo "make $kind"
        done
        ;;
    *)
        echo "使い方: Tools/check-stamp.sh tree | record <check|test> <tree> | record-remote <check|test> <tree> | missing <commit>" >&2
        exit 1
        ;;
esac
