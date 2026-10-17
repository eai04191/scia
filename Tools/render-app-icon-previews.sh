#!/bin/sh
# 設定でアイコンを選ぶ行に出す絵を、.iconからビルドのたびに描き出してアプリに入れる（App/Sources/Settings/AppIconChoice.swift）。
# アプリアイコンとしてしまわれた絵はUIImage(named:)で読めないため、別の画像として入れる。
# 描き出しにはXcodeに入っているIcon Composerのictoolを使う。見つからないときや描き出せないときは、ビルドを失敗させる。
set -eu

ictool="$(dirname "$DEVELOPER_DIR")/Applications/Icon Composer.app/Contents/Executables/ictool"
out="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"

# 2つのアイコンは同じ軌跡の形を使い、色だけをicon.jsonで変えている。
# .iconは自分のAssetsの中の画像しか参照できず、シンボリックリンクにするとictoolが白地に青の絵を欠けて描き出したため、同じファイルを2つ置き、片方だけ直したらビルドを止める
trail="$SRCROOT/App/Resources/AppIcon.icon/Assets/trail.svg"
light_trail="$SRCROOT/App/Resources/AppIconLight.icon/Assets/trail.svg"
if ! cmp -s "$trail" "$light_trail"; then
    echo "error: $light_trail が $trail と違います。軌跡の形を変えたら、もう片方にも同じファイルをコピーしてください" >&2
    exit 1
fi

# ダークや色付きの描き分けでは2つのアイコンがほぼ同じ見た目になり、選ぶ手がかりにならないため、ダークモードでも通常の見た目だけを描き出す
for name in AppIcon AppIconLight; do
    # 行には60ptで出すため、@3xの180pxで描き出す
    "$ictool" "$SRCROOT/App/Resources/$name.icon" --export-image \
        --output-file "$out/${name}Preview@3x.png" \
        --platform iOS --rendition Default --width 180 --height 180 --scale 1 >/dev/null
done
