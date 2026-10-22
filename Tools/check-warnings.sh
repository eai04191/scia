#!/bin/bash
# `make build`のあとに、アプリのSwiftの警告が1つでも残っていれば失敗する。
# SWIFT_TREAT_WARNINGS_AS_ERRORSを有効にしていても、@preconcurrency付きのAPI（SwiftUIのonGeometryChangeなど）を通る並行性の違反は、
# コンパイラーが警告に格下げし、-warnings-as-errorsでもエラーに戻らないため、ビルドは成功してしまう。
# ビルドのログは差分ビルドで作り直さなかったファイルの警告を出さないので、ログではなく、ファイルごとに残る診断ファイル（.dia）を読む。
# .diaは作り直すたびに置き換わり、診断がなければファイルのパスを含まない。診断があれば、そのファイルのパスと文言を含む。
# 見るのは`make build`が作るDebugのシミュレーター向けの、ビルドしたアーキテクチャだけ。同じDerivedDataで実機向けや別のアーキテクチャをビルドすると、そちらの古い診断が残り、直したあとも失敗し続けるため。
# 使い方: Tools/check-warnings.sh [<DerivedDataのパス>] [<アーキテクチャ>]
set -euo pipefail

DERIVED_DATA=${1:-DerivedData}
ARCH=${2:-$(uname -m)}
OBJECTS="$DERIVED_DATA/Build/Intermediates.noindex/Scia.build/Debug-iphonesimulator/Scia.build/Objects-normal/$ARCH"

if [[ ! -d "$OBJECTS" ]]; then
    echo "error: $OBJECTS がありません。先にmake buildを走らせてください" >&2
    exit 1
fi

found=0
# 同じファイルの診断が複数残ることがあるので、ファイルごとに1回だけ出す。macOSのbash 3.2には連想配列がないため、改行で区切った文字列で覚える
seen=$'\n'
while IFS= read -r -d '' dia; do
    source=$(strings -n 4 "$dia" | grep -m 1 '\.swift$' || true)
    # 診断のないファイルと、ソースを消したあとに残った古い診断ファイルは飛ばす
    if [[ -z "$source" || ! -f "$source" ]]; then
        continue
    fi
    found=1
    if [[ "$seen" == *$'\n'"$source"$'\n'* ]]; then
        continue
    fi
    seen+="$source"$'\n'
    echo "warning: $source" >&2
    strings -n 4 "$dia" | grep -v -e '^DIAG$' -e '\.swift$' -e '^C8< $' | sed 's/^/    /' >&2
done < <(find "$OBJECTS" -name '*.dia' -print0)

if [[ $found -ne 0 ]]; then
    echo "error: Swiftの警告が残っています" >&2
    exit 1
fi
