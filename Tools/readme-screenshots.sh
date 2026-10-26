#!/bin/bash
# READMEのスクリーンショットを、シナリオのUIテストを走らせて撮り、docs/imagesにWebPで書き出す（docs/promo-video.mdの「READMEのスクリーンショット」）。
# 使い方:
#   Tools/readme-screenshots.sh '<シミュレーターの名前>'
#   撮影用のビルド（Config/Promo.xcconfig）を、いつものSciaとは別のアプリとして入れて撮る。
#   UIテストが撮った画像を結果のバンドルの添付に残すので、添付の名前（screenshot-timelineなど）をファイルの名前にして書き出す。
#   撮る間は、ステータスバーを9:41、電波と電池を満タンに、外観をライトにし、ハードウェアキーボードをつなぐ。終わったらステータスバーと外観を戻す。
set -euo pipefail

BUNDLE_ID=net.mizle.scia.promo
TEST=SciaUITests/ReadmeScreenshotsUITests/testReadmeScreenshots

fail() {
    echo "readme-screenshots.sh: $*" >&2
    exit 1
}

[ $# -eq 1 ] || fail "使い方: Tools/readme-screenshots.sh '<シミュレーターの名前>'"
device=$1
destination="platform=iOS Simulator,name=$device"
# いつものビルドと成果物を上書きし合わないよう、プロモーション動画の素材と同じ場所に分ける。
derived_data=DerivedData/Promo
xcconfig=Config/Promo.xcconfig
work=$(mktemp -d)
test_log=$work/test.log

xcrun simctl bootstatus "$device" -b >/dev/null
xcodebuild -project Scia.xcodeproj -scheme SciaPromo -xcconfig "$xcconfig" -destination "$destination" -derivedDataPath "$derived_data" build-for-testing -quiet

appearance=$(xcrun simctl ui "$device" appearance)
restore() {
    xcrun simctl status_bar "$device" clear
    xcrun simctl ui "$device" appearance "$appearance"
}
trap restore EXIT

# ソフトウェアキーボードを出さず、投稿欄の後ろのタイムラインが見えるようにする。
swift Tools/sim-keyboard.swift "$device" hardware
xcrun simctl ui "$device" appearance light
xcrun simctl status_bar "$device" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --operatorName "" --batteryState discharging --batteryLevel 100
xcrun simctl terminate "$device" "$BUNDLE_ID" 2>/dev/null || true

xcodebuild -project Scia.xcodeproj -scheme SciaPromo -xcconfig "$xcconfig" -destination "$destination" -derivedDataPath "$derived_data" \
    -collect-test-diagnostics never -resultBundlePath "$work/result.xcresult" test-without-building -only-testing:"$TEST" >"$test_log" 2>&1 \
    || { tail -30 "$test_log" >&2; fail "シナリオが失敗した。全体は$test_log"; }

xcrun xcresulttool export attachments --path "$work/result.xcresult" --output-path "$work/attachments" >/dev/null
# manifest.jsonには、テストごとに、添付の名前（suggestedHumanReadableName）と書き出したファイルの名前（exportedFileName）が並ぶ。
# 名前には、添付の名前の後ろに番号と拡張子が付くので、最初の「_」より前を使う。
count=0
while IFS=$'\t' read -r name file; do
    cwebp -quiet -q 85 -m 6 "$work/attachments/$file" -o "docs/images/$name.webp"
    echo "docs/images/$name.webp"
    count=$((count + 1))
done < <(jq -r '.[].attachments[] | [(.suggestedHumanReadableName | split("_")[0]), .exportedFileName] | @tsv' "$work/attachments/manifest.json")
[ "$count" -gt 0 ] || fail "結果のバンドルにスクリーンショットがない。$work/attachments/manifest.json"
