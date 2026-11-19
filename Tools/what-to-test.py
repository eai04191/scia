#!/usr/bin/env python3
"""TestFlightのWhat to Testを、前に上げたcommitから今のcommitまでの使う人向けの変更（dev scopeのない feat・fix・perf）から書き出す。

使い方: what-to-test.py <前に上げたcommit> <今のcommit> <リポジトリのURL>

先頭に比較ページのURLと種類ごとの件数を書き、その後ろにcommitの件名を古い順に並べる。
App Store ConnectはWhat to Testが4000文字を超えると断るので、収まらない件名は後ろから外し、外した件数を最後の行に書く。
文字数は、Appleがどの単位で数えるかが書かれていないため、絵文字などで多めに数えるUTF-16の単位で数える。
`--self-test`で、件名の選び方と文字数の収め方を確かめる。
"""

import re
import subprocess
import sys

LIMIT = 4000
USER_FACING = re.compile(r'^(feat|fix|perf)(\(([^)]*)\))?!?: ')
KIND_NAMES = (('feat', '機能追加'), ('fix', '修正'), ('perf', 'パフォーマンス改善'))


def length(text):
    return len(text.encode('utf-16-le')) // 2


def user_facing(subjects):
    picked = []
    for subject in subjects:
        match = USER_FACING.match(subject)
        if match and match.group(3) != 'dev':
            picked.append((match.group(1), subject))
    return picked


def compose(subjects, compare_url, limit=LIMIT):
    changes = user_facing(subjects)
    if not changes:
        return f'GitHubで見る: {compare_url}\n\n前回のリリースから、使う人に見える変更はありません。\n'
    counts = [f'{sum(kind == key for kind, _ in changes)}件の{name}' for key, name in KIND_NAMES]
    counts = [count for count in counts if not count.startswith('0件')]
    text = f'GitHubで見る: {compare_url}\n\n前回のリリースから、{"、".join(counts)}が含まれています。\n\n'
    lines = [f'* {subject}\n' for _, subject in changes]
    for shown in range(len(lines), -1, -1):
        rest = len(lines) - shown
        tail = f'* ほか{rest}件はGitHubで確認できます\n' if rest else ''
        candidate = text + ''.join(lines[:shown]) + tail
        if length(candidate) <= limit:
            return candidate
    raise SystemExit('what-to-test: 比較ページのURLと件数だけで上限を超える')


def main(last, head, repository_url):
    log = subprocess.run(
        ['git', 'log', '--reverse', '--format=%s', f'{last}..{head}'],
        check=True, capture_output=True, text=True,
    ).stdout
    sys.stdout.write(compose(log.splitlines(), f'{repository_url}/compare/{last}...{head}'))
    return 0


def self_test():
    failed = False

    def check(name, actual, expected):
        nonlocal failed
        if actual != expected:
            failed = True
            print(f'{name}: {actual!r} != {expected!r}')

    subjects = ['feat: A', 'fix(dev): B', 'chore: C', 'fix(timeline): D', 'perf!: E', 'feat(dev): F', 'feature: G']
    check('選ぶ件名', [subject for _, subject in user_facing(subjects)], ['feat: A', 'fix(timeline): D', 'perf!: E'])
    check('全部入る', compose(subjects, 'URL'),
          'GitHubで見る: URL\n\n前回のリリースから、1件の機能追加、1件の修正、1件のパフォーマンス改善が含まれています。\n\n'
          '* feat: A\n* fix(timeline): D\n* perf!: E\n')
    check('0件の種類は書かない', compose(['feat: A', 'feat: B'], 'URL'),
          'GitHubで見る: URL\n\n前回のリリースから、2件の機能追加が含まれています。\n\n* feat: A\n* feat: B\n')
    check('変更がない', compose(['chore: A'], 'URL'), 'GitHubで見る: URL\n\n前回のリリースから、使う人に見える変更はありません。\n')

    many = [f'feat: 項目{index:03}' for index in range(500)]
    composed = compose(many, 'URL')
    check('上限に収まる', length(composed) <= LIMIT, True)
    check('古い順に残す', composed.split('\n')[4], '* feat: 項目000')
    shown = composed.count('* feat: ')
    check('外した件数', composed.endswith(f'* ほか{500 - shown}件はGitHubで確認できます\n'), True)
    check('件数は外したものも数える', '500件の機能追加' in composed, True)
    check('UTF-16で数える', length('😀'), 2)

    print('self-test ' + ('失敗' if failed else 'OK'))
    return 1 if failed else 0


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        sys.exit(self_test())
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
