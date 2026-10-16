#!/bin/sh
# ビルドしたアプリのInfo.plistに、ビルド元のブランチとcommitを書き込む。
# 実機でいろいろなブランチのビルドを入れ替えて試すときに、いま入っているのがどれか分かるようにする（App/Sources/BuildInfo.swift）。
# 未commitの変更を含むビルドは、commitに「-dirty」を付ける。gitで読めないときは、ビルドを失敗させる。
set -eu

if [ -n "${SCIA_GIT_BRANCH:-}${SCIA_GIT_COMMIT:-}" ]; then
    # scia-tryはgit archiveで書き出したソースをビルドし、そこには.gitがないため、ビルド設定で受け取る。
    # 書き出したのはcommitそのものなので、未commitの変更は含まない
    branch=${SCIA_GIT_BRANCH:?SCIA_GIT_COMMITを渡すときはSCIA_GIT_BRANCHも渡す}
    commit=${SCIA_GIT_COMMIT:?SCIA_GIT_BRANCHを渡すときはSCIA_GIT_COMMITも渡す}
else
    branch=$(git -C "$SRCROOT" symbolic-ref --short -q HEAD || echo "(detached HEAD)")
    commit=$(git -C "$SRCROOT" rev-parse --short HEAD)
    # 条件式の中のコマンド置換は、失敗してもset -eで止まらないため、先に代入して失敗をビルドの失敗にする
    status=$(git -C "$SRCROOT" status --porcelain)
    if [ -n "$status" ]; then
        commit="$commit-dirty"
    fi
fi

plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
plutil -replace SciaGitBranch -string "$branch" "$plist"
plutil -replace SciaGitCommit -string "$commit" "$plist"
