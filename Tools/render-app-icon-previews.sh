#!/bin/sh
# 設定でアイコンを選ぶ行に出す絵を、.iconからビルドのたびに描き出してアプリに入れる（App/Sources/Settings/AppIconChoice.swift）。
# アプリアイコンとしてしまわれた絵はUIImage(named:)で読めないため、別の画像として入れる。
# 描き出しにはXcodeに入っているIcon Composerのictoolを使う。見つからないときや描き出せないときは、ビルドを失敗させる。
set -eu

ictool="$(dirname "$DEVELOPER_DIR")/Applications/Icon Composer.app/Contents/Executables/ictool"
out="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"

# ダークや色付きの描き分けでは2つのアイコンがほぼ同じ見た目になり、選ぶ手がかりにならないため、ダークモードでも通常の見た目だけを描き出す
for name in AppIcon AppIconLight; do
    # 行には60ptで出すため、@3xの180pxで描き出す
    "$ictool" "$SRCROOT/App/Resources/$name.icon" --export-image \
        --output-file "$out/${name}Preview@3x.png" \
        --platform iOS --rendition Default --width 180 --height 180 --scale 1 >/dev/null
done
