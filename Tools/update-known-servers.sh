#!/bin/sh
# ログイン画面の補完に使うサーバーの一覧を、FediDBのデータセット（CC BY 4.0）から作り直す。
# Mastodonとその派生を、月間アクティブ数の多い順に1行1ドメインで書き出す。
# FediDBの出力は週1回なので、GitHub Actionsで週1回走らせてPRにする。
set -eu

out=Packages/SciaCore/Sources/SciaCore/Auth/Resources/known-servers.txt
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

curl -fsSL https://api.fedidb.org/datasets/servers.json.gz | gunzip | jq -r '
  ["mastodon", "hometown", "fedibird", "kmyblue", "ecko"] as $software
  | map(select(.software as $s | $software | index($s)))
  | sort_by(-(.monthly_active // 0), .domain)
  | .[].domain | ascii_downcase
' > "$tmp"

chmod 644 "$tmp"

# 取得や絞り込みの失敗で一覧が空や極端に短くなったら、置き換えずに失敗させる。
count=$(wc -l < "$tmp")
if [ "$count" -lt 1000 ]; then
  echo "サーバーが${count}件しかないため、一覧を置き換えません" >&2
  exit 1
fi
mv "$tmp" "$out"
trap - EXIT
echo "${count}件のサーバーを書き出しました: $out"
