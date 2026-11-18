#!/bin/bash
# 毎朝4:50（Macのローカル時刻）に、ローカルのmainをoriginへpushするLaunchAgentを入れる・外す。
# 5:00のTestFlightのworkflow（.github/workflows/testflight.yml）に、前の日にmainへ入れたものを載せるため。
# pushするのはmainのcheckout（git rev-parse --git-common-dirの親）のrefs/heads/mainだけで、force pushはしない。
# merge-queueが走っている途中でも待たない。
#
#   Tools/scheduled-push.sh install    LaunchAgentを書き出して読み込む（何度走らせても同じ状態になる）
#   Tools/scheduled-push.sh uninstall  LaunchAgentを止めて消す
#
# 結果は~/Library/Logs/scia-scheduled-push.logに残る。
# LaunchAgentはgitを直接呼ぶので、このスクリプトがmainに入っていなくても動く。
set -euo pipefail

label=net.mizle.scia.scheduled-push
plist="$HOME/Library/LaunchAgents/$label.plist"
log="$HOME/Library/Logs/scia-scheduled-push.log"
domain="gui/$(id -u)"

# 読み込まれていなければ何もしない。止められずに残ったときは失敗にする
unload() {
	launchctl print "$domain/$label" >/dev/null 2>&1 || return 0
	launchctl bootout "$domain/$label"
}

case "${1:-}" in
install)
	repo=$(cd "$(git rev-parse --git-common-dir)/.." && pwd -P)
	git=$(command -v git)
	command -v git-lfs >/dev/null || { echo "git-lfsが見つかりません（pre-pushのhookが使う）" >&2; exit 1; }
	path="$(dirname "$(command -v git-lfs)"):/usr/bin:/bin"
	mkdir -p "$(dirname "$plist")" "$(dirname "$log")"
	# パスに&や<があっても壊れないよう、XMLを手で書かずplutilで組み立てる
	tmp=$(mktemp)
	plutil -create xml1 "$tmp"
	plutil -insert Label -string "$label" "$tmp"
	plutil -insert ProgramArguments -array "$tmp"
	for arg in "$git" -C "$repo" push origin refs/heads/main:refs/heads/main; do
		plutil -insert ProgramArguments -string "$arg" -append "$tmp"
	done
	plutil -insert EnvironmentVariables -dictionary "$tmp"
	plutil -insert EnvironmentVariables.PATH -string "$path" "$tmp"
	plutil -insert StartCalendarInterval -dictionary "$tmp"
	plutil -insert StartCalendarInterval.Hour -integer 4 "$tmp"
	plutil -insert StartCalendarInterval.Minute -integer 50 "$tmp"
	plutil -insert StandardOutPath -string "$log" "$tmp"
	plutil -insert StandardErrorPath -string "$log" "$tmp"
	mv "$tmp" "$plist"
	plutil -lint "$plist" >/dev/null
	unload
	launchctl bootstrap "$domain" "$plist"
	echo "毎朝4:50に${repo}のmainをpushします（ログ: ${log}）"
	;;
uninstall)
	unload
	rm -f "$plist"
	echo "自動pushを外しました"
	;;
*)
	echo "使い方: $0 install|uninstall" >&2
	exit 64
	;;
esac
