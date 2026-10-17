#!/bin/bash
# 今のworktreeの状態（commit済み、未commit、未追跡のファイル）を、使い捨ての複製に再現する。
# 複製はこのリポジトリのオブジェクトを共有するcloneで、remoteは外す。複製での操作がこのリポジトリのbranchに届かないようにするため。
# 使い方: make-copy.sh <作る場所>（まだない場所を渡す）
set -euo pipefail

dest="${1:?作る場所を渡す}"
root="$(git rev-parse --show-toplevel)"
head="$(git -C "$root" rev-parse HEAD)"

if [ -e "$dest" ]; then
    echo "すでにある: $dest" >&2
    exit 1
fi

git clone --quiet --shared --no-checkout "$root" "$dest"
git -C "$dest" remote remove origin
git -C "$dest" checkout --quiet --detach "$head"

# 未commitの変更（stagedとunstaged）
git -C "$root" diff --binary HEAD | git -C "$dest" apply --allow-empty

# 未追跡のファイル（.gitignoreとinfo/excludeで除いたものは含めない）
git -C "$root" ls-files --others --exclude-standard -z \
    | rsync -a --from0 --files-from=- "$root/" "$dest/"

echo "$dest"
