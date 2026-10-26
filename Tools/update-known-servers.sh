#!/bin/sh
# ログイン画面の補完に使うサーバーの一覧を、FediDBのデータセット（CC BY 4.0）から作り直す。
# Mastodonとその派生を、月間アクティブ数の多い順に1行1ドメインで書き出す。FediDBに載らないサーバーはTools/known-servers-extra.txtで足す。
# FediDBの出力は週1回なので、GitHub Actionsで週1回走らせてPRにする。
set -eu

out=Packages/SciaCore/Sources/SciaCore/Auth/Resources/known-servers.txt
tmp=$(mktemp)
extra=Tools/known-servers-extra.txt
software='["mastodon", "hometown", "fedibird", "kmyblue", "ecko"]'
fedidb=$(mktemp)
extras=$(mktemp)
trap 'rm -f "$tmp" "$fedidb" "$extras"' EXIT

curl -fsSL https://api.fedidb.org/datasets/servers.json.gz | gunzip > "$fedidb"

# FediDBのデータセットに載らないサーバー（pawoo.netなど）は、$extraに書き、
# 月間アクティブ数をそのサーバーのNodeInfoから読んで、FediDBの分と同じ順に並べる。
# 読めなければ、黙って抜かすと気づかないうちに一覧から消えるので、置き換えずに失敗させる。
while IFS= read -r domain || [ -n "$domain" ]; do
  if ! links=$(curl -fsSL "https://$domain/.well-known/nodeinfo"); then
    echo "${domain}のNodeInfoを読めないため、一覧を置き換えません" >&2
    exit 1
  fi
  href=$(printf '%s' "$links" | jq -r '
    [.links[] | select(.rel == "http://nodeinfo.diaspora.software/ns/schema/2.0")][0].href // empty
  ')
  if [ -z "$href" ]; then
    echo "${domain}のNodeInfo 2.0の場所が分からないため、一覧を置き換えません" >&2
    exit 1
  fi
  if ! nodeinfo=$(curl -fsSL "$href"); then
    echo "${domain}のNodeInfoを読めないため、一覧を置き換えません" >&2
    exit 1
  fi
  if ! printf '%s' "$nodeinfo" | jq -e '.usage.users.activeMonth | type == "number"' > /dev/null; then
    echo "${domain}の月間アクティブ数が読めないため、一覧を置き換えません" >&2
    exit 1
  fi
  if ! printf '%s' "$nodeinfo" | jq -e --argjson software "$software" '.software.name as $s | $software | index($s)' > /dev/null; then
    echo "${domain}のソフトウェアがMastodonとその派生でないため、一覧を置き換えません" >&2
    exit 1
  fi
  printf '%s' "$nodeinfo" | jq -c --arg domain "$domain" '
    {domain: $domain, software: .software.name, monthly_active: .usage.users.activeMonth}
  ' >> "$extras"
done < "$extra"

jq -r --slurpfile extras "$extras" --argjson software "$software" '
  . + $extras
  | map(select(.software as $s | $software | index($s)))
  | map(.domain |= ascii_downcase)
  | unique_by(.domain)
  | sort_by(-(.monthly_active // 0), .domain)
  | .[].domain
' "$fedidb" > "$tmp"

chmod 644 "$tmp"

# 取得や絞り込みの失敗で一覧が空や極端に短くなったら、置き換えずに失敗させる。
# 一覧だけの更新は、make checkとmake testを走らせ直さずにmainへ入れる（Tools/check-stamp.sh）ので、
# 一覧を読むテスト（ServerSuggestionsTestsのloadsTheBundledList）と同じ条件をここで確かめる。
count=$(wc -l < "$tmp")
if [ "$count" -le 1000 ]; then
  echo "サーバーが${count}件しかないため、一覧を置き換えません" >&2
  exit 1
fi
if ! grep -qx 'mastodon.social' "$tmp"; then
  echo "一覧にmastodon.socialがないため、置き換えません" >&2
  exit 1
fi
if grep -qx '' "$tmp"; then
  echo "一覧に空の行があるため、置き換えません" >&2
  exit 1
fi
mv "$tmp" "$out"
rm -f "$fedidb" "$extras"
trap - EXIT
echo "${count}件のサーバーを書き出しました: $out"
