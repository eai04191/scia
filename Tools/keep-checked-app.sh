#!/bin/bash
# make check、make testが通ったあと、そのビルドのアプリを<DerivedData>/checked/Scia.appにコピーし、確かめたtreeを<DerivedData>/checked/treeに書く。
# 別のMacで通った回は、Tools/test-dispatch.shがこのフォルダーを手元へ受け取る。どちらで走っても、通ったあとはここのアプリをシミュレーターに入れれば、make buildし直さずに済む。
# Build/Productsへ受け取らないのは、別のMacでビルドした中身が、手元の差分ビルドの成果物に混ざらないようにするため。
# 使い方: Tools/keep-checked-app.sh <tree> <MakefileのDERIVED_DATA>
set -euo pipefail

tree=${1:?確かめたtreeを渡す}
derived=${2:?MakefileのDERIVED_DATAを渡す}
app=$derived/Build/Products/Debug-iphonesimulator/Scia.app
[[ -d "$app" ]] || { echo "error: $app がありません" >&2; exit 1; }
rm -rf "$derived/checked"
mkdir -p "$derived/checked"
# APFSのクローンでコピーするので、100MBほどのアプリでもすぐ終わる
cp -Rc "$app" "$derived/checked/"
echo "$tree" > "$derived/checked/tree"
echo "確かめた中身のアプリは$(cd "$derived/checked" && pwd)/Scia.appに置きました"
