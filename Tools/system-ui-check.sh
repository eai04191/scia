#!/bin/bash
# UIKitの公開されていない作りに頼っている部分を、UIテスト（SciaSystemUITests）で確かめる。make testから呼ぶ。
# 壊れうるのはiOSの版が変わったときなので、シミュレーターのiOSのビルド番号ごとに一度だけ走らせる。頼っている部分のコードとテストを変えたときも走らせ直す。
# 通ったものは、Tools/check-stamp.shと同じく、worktreeどうしで共有する.gitの共通ディレクトリのscia-check/system-ui/に、
# ビルド番号と、頼っている部分のファイルの中身のハッシュを名前にした空のファイルで覚える。
# 使い方: Tools/system-ui-check.sh <端末の名前> <DerivedDataのパス>。端末の環境変数から版を読むので、起動している端末を渡す（make testのテストのあとに呼ぶ）
set -euo pipefail

sim=${1:?端末の名前を渡す}
derived_data=${2:?DerivedDataのパスを渡す}

build=$(xcrun simctl getenv "$sim" SIMULATOR_RUNTIME_BUILD_VERSION)
version=$(xcrun simctl getenv "$sim" SIMULATOR_RUNTIME_VERSION)
stamp_dir="$(git rev-parse --git-common-dir)/scia-check/system-ui"
# UIKitの公開されていない作りに頼っているコードと、それを確かめるUIテスト。変えたら走らせ直す
watched=(App/Sources/Navigation/ContextMenuPositioner.swift App/Sources/Navigation/TabArrangement.swift AppSystemUITests Tools/system-ui-check.sh)
content=$(find "${watched[@]}" -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -c1-16)
stamp="${build}-${content}"

if [[ -e "$stamp_dir/$stamp" ]]; then
    exit 0
fi

# 変数のすぐ後ろに全角の文字を置くと、macOSのBash 3.2が変数名の切れ目を読み違えるので、波括弧で区切る
echo "シミュレーターのiOS ${version}（${build}）と今のコードでは、まだSciaSystemUITestsを通していないので走らせます"
xcodebuild -project Scia.xcodeproj -scheme SciaSystemUITests -destination "platform=iOS Simulator,name=$sim" -derivedDataPath "$derived_data" -collect-test-diagnostics never test
mkdir -p "$stamp_dir"
touch "$stamp_dir/$stamp"
