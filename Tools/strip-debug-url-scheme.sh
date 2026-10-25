#!/bin/sh
# DEBUGでコンパイルしないビルド（Release）のInfo.plistから、デバッグ用のURLスキーム（scia-debug）の登録を消す。
# 受け取る処理（App/Sources/Debug/DebugURL.swift）は#if DEBUGの中にあり、残しておくと、ほかのアプリやWebページから開かれたときにアプリが手前に出るだけになる。
# XcodeGenはInfo.plistを構成によらず1つ作るため、ビルドしたあとに消す。
# 差分ビルドではInfo.plistが作り直されず、前のビルドで消したままのことがあるので、SciaDebugURLSchemeもないときは消し終えたものとして何もしない。
# SciaDebugURLSchemeがあるのにURLスキームの登録が見つからないときは、project.ymlと食い違っているのでビルドを失敗させる。
set -eu

case " ${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-} " in
    *" DEBUG "*) exit 0 ;;
esac

plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
buddy=/usr/libexec/PlistBuddy
if ! plutil -extract SciaDebugURLScheme raw "$plist" >/dev/null 2>&1; then
    exit 0
fi
count=$(plutil -extract CFBundleURLTypes raw "$plist")
i=0
while [ "$i" -lt "$count" ]; do
    name=$("$buddy" -c "Print :CFBundleURLTypes:$i:CFBundleURLName" "$plist")
    if [ "$name" = "net.mizle.scia.debug" ]; then
        "$buddy" -c "Delete :CFBundleURLTypes:$i" -c "Delete :SciaDebugURLScheme" "$plist"
        exit 0
    fi
    i=$((i + 1))
done
echo "error: Info.plistにnet.mizle.scia.debugのURLスキームがない" >&2
exit 1
