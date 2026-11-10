#!/bin/bash
# `make build`のあとに、アプリのSwiftの警告が1つでも残っていれば失敗する。
# SWIFT_TREAT_WARNINGS_AS_ERRORSを有効にしていても、@preconcurrency付きのAPI（SwiftUIのonGeometryChangeなど）を通る並行性の違反は、
# コンパイラーが警告に格下げし、-warnings-as-errorsでもエラーに戻らないため、ビルドは成功してしまう。
# ビルドのログは差分ビルドで作り直さなかったファイルの警告を出さないので、ログではなく、ファイルごとに残る診断ファイル（.dia）を読む。
# .diaは作り直すたびに置き換わる。警告は、同じ回にまとめてコンパイルしたほかのファイルの.diaにも、警告の出たファイルのパスと文言で入る。
# 警告を直しても、まとめてコンパイルした相手は作り直されず、そこに古い警告が残る。警告の出たファイル自身の.diaには必ず入るので、.diaごとに、自分のソースのパスを含むものだけを数える。
# 通常は、警告のないファイルの.diaは自分のソースのパスを含まない。例外は、まとめてコンパイルした相手の警告の補足（note）がこのファイルの宣言を指していた場合で、相手を直したあとも、このファイルを作り直すまで失敗する。
# 起きるのは、補足の指す先が別のファイルにある警告を、その2つが同じ回にコンパイルされたビルドで出したときだけ。なくすには.diaのビットストリームを読んで診断ごとの位置を取り出す必要があるので、対応していない。
# .diaとソースの対応は、ビルドが残す対応表（Scia-OutputFileMap.json）で引く。対応表にない.diaは、消したソースの残りなので読まない。
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

MAP="$OBJECTS/Scia-OutputFileMap.json"
if [[ ! -f "$MAP" ]]; then
    echo "error: $MAP がありません。先にmake buildを走らせてください" >&2
    exit 1
fi

# 対応表を読めなければ、警告なしとして通さずに失敗する。プロセス置換の中の失敗はset -eで止まらないので、先に読み切る
pairs=$(python3 -c '
import json, sys
for source, outputs in json.load(open(sys.argv[1])).items():
    if source and "diagnostics" in outputs:
        print(source, outputs["diagnostics"], sep="\t")
' "$MAP")

found=0
while IFS=$'\t' read -r source dia; do
    # grep -qは使わない。一致したところで読むのをやめ、大きい.diaではstringsがSIGPIPEで終わり、pipefailで一致しなかった扱いになるため
    if [[ ! -f "$dia" ]] || ! strings -n 4 "$dia" | grep -Fx -- "$source" > /dev/null; then
        continue
    fi
    found=1
    # 別のMacで走らせたときに手元へ返す行（Tools/remote-test-worker.shが`: error: `で選ぶ）に文言が載るよう、1行で出す。説明のページのURLだけの行は除く
    detail=$(strings -n 4 "$dia" | { grep -v -e '^DIAG$' -e '\.swift$' -e '^C8< $' -e '^https\{0,1\}://' -e '@https\{0,1\}://' || true; } | paste -sd '|' - | sed 's/|/ \/ /g')
    echo "$source: error: Swiftの警告が残っています: $detail" >&2
done <<< "$pairs"

if [[ $found -ne 0 ]]; then
    exit 1
fi
