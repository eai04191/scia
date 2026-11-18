#!/bin/sh
# 設定でアイコンを選ぶ行に出す絵を、.iconからビルドのたびに描き出してアプリに入れる（App/Sources/Settings/AppIconChoice.swift）。
# アプリアイコンとしてしまわれた絵はUIImage(named:)で読めないため、別の画像として入れる。
# 描き出しにはXcodeに入っているIcon Composerのictoolを使う。見つからないときや描き出せないときは、ビルドを失敗させる。
set -eu

ictool="$(dirname "$DEVELOPER_DIR")/Applications/Icon Composer.app/Contents/Executables/ictool"
out="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"

# どのアイコンも同じ軌跡の形を使い、色（とScia Tryの作図線）だけをicon.jsonで変えている。
# .iconは自分のAssetsの中の画像しか参照できず、シンボリックリンクにするとictoolが白地に青の絵を欠けて描き出したため、同じファイルを置き、1つだけ直したらビルドを止める
trail="$SRCROOT/App/Resources/AppIcon.icon/Assets/trail.svg"
for other in AppIconLight AppIconTry; do
    other_trail="$SRCROOT/App/Resources/$other.icon/Assets/trail.svg"
    if ! cmp -s "$trail" "$other_trail"; then
        echo "error: $other_trail が $trail と違います。軌跡の形を変えたら、ほかのアイコンにも同じファイルをコピーしてください" >&2
        exit 1
    fi
done

# ダークや色付きの描き分けでは2つのアイコンがほぼ同じ見た目になり、選ぶ手がかりにならないため、ダークモードでも通常の見た目だけを描き出す
# 「青地に白」の行（AppIconPreview）には、ホーム画面と同じ絵が出るよう、このビルドの主アイコン（project.ymlのSCIA_APP_ICON）を描く
for pair in "$SCIA_APP_ICON:AppIcon" AppIconLight:AppIconLight; do
    source=${pair%%:*}
    name=${pair#*:}
    # 行には60ptで出すため、@3xの180pxで描き出す
    "$ictool" "$SRCROOT/App/Resources/$source.icon" --export-image \
        --output-file "$out/${name}Preview@3x.png" \
        --platform iOS --rendition Default --width 180 --height 180 --scale 1 >/dev/null
done

# 「投稿の見た目」の見本のアイコンとカスタム絵文字に使う、角まで絵の詰まった四角の絵（App/Sources/Settings/PreviewImages.swift）。
# 縮めた.iconを1024pxで書き出し、真ん中の768pxを切り出して、アイコンの大きさの上限（200pt）の@3xに近い512pxにする。
# 0.75は、角丸の切り抜きと縁の線が切り出す範囲に入らない倍率（180pxの書き出しで、角の対角線上の13pxまでが透明で、その内側に縁の線がある）。
square=$(mktemp -d)
trap 'rm -rf "$square"' EXIT
/usr/bin/python3 "$SRCROOT/Tools/square-app-icon.py" "$SRCROOT/App/Resources/$SCIA_APP_ICON.icon" "$square/Square.icon" 0.75
"$ictool" "$square/Square.icon" --export-image \
    --output-file "$square/square.png" \
    --platform iOS --rendition Default --width 1024 --height 1024 --scale 1 >/dev/null
sips --cropToHeightWidth 768 768 "$square/square.png" --out "$square/cropped.png" >/dev/null
sips --resampleHeightWidth 512 512 "$square/cropped.png" --out "$out/AppIconSquarePreview.png" >/dev/null
