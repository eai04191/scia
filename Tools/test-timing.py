#!/usr/bin/env python3
"""make testで1件ずつのテストにかかった時間を、treeごとに覚えて比べる。決まりはdocs/test-dispatch.mdの「テストの時間」。

使い方:
  Tools/test-timing.py record <tree> <xcresult>...           xcresultから1件ずつの時間を読み、通ったtreeの時間として覚える
  Tools/test-timing.py import <tree>                          標準入力の記録（別のMacで覚えたもの）を、通ったtreeの時間として覚える
  Tools/test-timing.py warn                                   今の作業ツリーのtreeを分岐元のmainと比べ、基準を超えたテストを出す。終了コードは常に0
  Tools/test-timing.py gate <base> <commit>                   <commit>を<base>と比べる。記録がなければmake testを走らせて作る

gateの終了コード: 0 基準を超えたテストがない、1 想定外の失敗、7 基準を超えたテストがある、
  止められたとき（SIGTERM、SIGINT、SIGHUP）はシグナルの番号に128を足したもの
"""

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

TARGET = 'main'
# 遅くなったとみなす基準。今のテストの多くは0.1秒未満で、負荷のぶれではこの幅を超えない
MIN_INCREASE_SECONDS = 1.0
MIN_RATIO = 2.0
NEW_TEST_LIMIT_SECONDS = 1.0
# 記録のあるcommitを探すときに、さかのぼる数の上限
SEARCH_LIMIT = 200
SLOW = 7
# nodeIdentifierURLは「test://com.apple.xcode/<プロジェクト>/<バンドル>/…」の形で、プロジェクトの部分はScia、SciaCoreなどテストごとに違う
URL_PREFIX = 'test://com.apple.xcode/'


def git(*arguments, cwd=None, check=True):
    result = subprocess.run(['git', *arguments], cwd=cwd, text=True, capture_output=True)
    if check and result.returncode != 0:
        raise SystemExit(f'error: git {" ".join(arguments)} が失敗しました: {result.stderr.strip()}')
    return result


def common_dir():
    return Path(git('rev-parse', '--path-format=absolute', '--git-common-dir').stdout.strip())


def timing_dir():
    return common_dir() / 'scia-check' / 'timing'


def record_path(tree):
    return timing_dir() / f'{tree}.tsv'


def tree_of(commit):
    return git('rev-parse', f'{commit}^{{tree}}').stdout.strip()


def test_name(url):
    path = url.split('?')[0]
    if not path.startswith(URL_PREFIX):
        raise SystemExit(f'error: テストの識別子の形が想定と違います: {url}')
    return path.removeprefix(URL_PREFIX).split('/', 1)[1]


def record(tree, results):
    durations = {}
    for result in results:
        process = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', result],
                                 text=True, capture_output=True)
        if process.returncode != 0:
            raise SystemExit(f'error: {result} からテストの時間を読めませんでした: {process.stderr.strip()}')
        for node in json.loads(process.stdout)['testNodes']:
            collect(node, durations)
    if not durations:
        raise SystemExit('error: xcresultにテストの時間がありませんでした')
    lines = [f'# host {socket.gethostname().split(".")[0]}']
    lines += [f'{name}\t{seconds:.3f}' for name, seconds in sorted(durations.items())]
    store(tree, '\n'.join(lines) + '\n')


def collect(node, durations):
    if node.get('nodeType') == 'Test Case':
        name = test_name(node.get('nodeIdentifierURL', ''))
        durations[name] = durations.get(name, 0.0) + float(node.get('durationInSeconds') or 0.0)
        return
    for child in node.get('children', []):
        collect(child, durations)


def import_record(tree, text):
    if not parse(text)[1]:
        raise SystemExit('error: 受け取った記録にテストの時間がありませんでした')
    store(tree, text)


def store(tree, text):
    timing_dir().mkdir(parents=True, exist_ok=True)
    # 書きかけの記録を、ほかのプロセスが読まないよう、別の名前で書いてから置き換える。
    # 同じtreeを別のworktreeで同時に記録することがあるので、名前は書くたびに分ける
    with tempfile.NamedTemporaryFile('w', dir=timing_dir(), prefix=f'{tree}.', suffix='.tmp', delete=False) as file:
        file.write(text)
    os.replace(file.name, record_path(tree))


def load(tree):
    return parse(record_path(tree).read_text())


def parse(text):
    host = '不明'
    durations = {}
    for line in text.splitlines():
        if line.startswith('# host '):
            host = line.removeprefix('# host ')
        elif line and not line.startswith('#'):
            name, seconds = line.split('\t')
            durations[name] = float(seconds)
    return host, durations


def only_unchecked_files_differ(a, b):
    # Tools/check-stamp.shと同じく、Markdownとサーバーのリストだけの違いはテストの中身を変えない
    result = git('diff', '--quiet', '--no-renames', a, b, '--', '.', ':(exclude)*.md',
                 ':(exclude)Packages/SciaCore/Sources/SciaCore/Auth/Resources/known-servers.txt', check=False)
    if result.returncode not in (0, 1):
        raise SystemExit(f'error: {a} と {b} を比べられませんでした: {result.stderr.strip()}')
    return result.returncode == 0


def find_record(commit):
    """<commit>とテストの中身が同じで、時間の記録があるcommitのtreeを返す。なければNone"""
    commits = git('rev-list', '--first-parent', f'--max-count={SEARCH_LIMIT}', commit).stdout.split()
    for candidate in commits:
        if candidate != commits[0] and not only_unchecked_files_differ(candidate, commits[0]):
            return None
        tree = tree_of(candidate)
        if record_path(tree).exists():
            return tree
    return None


def slow_tests(base, current):
    found = []
    for name, seconds in sorted(current.items()):
        before = base.get(name)
        if before is None:
            if seconds >= NEW_TEST_LIMIT_SECONDS:
                found.append((name, None, seconds))
        elif seconds - before >= MIN_INCREASE_SECONDS and seconds >= before * MIN_RATIO:
            found.append((name, before, seconds))
    return found


def compare(base_tree, tree, base_label):
    base_host, base = load(base_tree)
    host, current = load(tree)
    print(f'テストの時間を{base_label}（{base_host}で計測）と比べました（このtreeは{host}で計測）')
    print(f'合計: {sum(base.values()):.1f}秒 → {sum(current.values()):.1f}秒')
    found = slow_tests(base, current)
    if not found:
        print('基準を超えて遅くなったテストはありません')
        return []
    print(f'基準（{MIN_INCREASE_SECONDS:g}秒以上かつ{MIN_RATIO:g}倍以上の増加、新しいテストは{NEW_TEST_LIMIT_SECONDS:g}秒以上）を超えたテスト:')
    for name, before, seconds in found:
        change = '新しいテスト' if before is None else f'{before:.2f}秒 →'
        print(f'  {name}  {change} {seconds:.2f}秒')
    return found


def warn():
    tree = subprocess.run(['Tools/check-stamp.sh', 'tree'], text=True, capture_output=True, check=True).stdout.strip()
    if not record_path(tree).exists():
        print('make testを走らせている間に作業ツリーが変わったので、テストの時間を比べられません')
        return
    base_commit = git('merge-base', 'HEAD', TARGET).stdout.strip()
    base_tree = find_record(base_commit)
    if base_tree is None:
        print(f'分岐元の{TARGET}（{base_commit[:12]}）の時間の記録がないので、テストの時間はmerge-to-mainで比べます')
        return
    if compare(base_tree, tree, f'分岐元の{TARGET}（{base_commit[:12]}）'):
        print('merge-to-mainはこのままでは止まります。遅くなったテストを直してください')


class Stopped(Exception):
    def __init__(self, number):
        super().__init__(number)
        self.number = number


def on_signal(number, frame):
    raise Stopped(number)


def run_test(cwd):
    # mainへ入れる列が待っているので、先頭に並ぶ
    process = subprocess.Popen(['Tools/test-dispatch.sh', 'dispatch', 'test', '', '', 'front'], cwd=cwd)
    try:
        status = process.wait()
    except Stopped:
        # 止める合図はプロセスグループごと届き、子は端末を返すなどの後片付けをしてから終わる。
        # 一時的なworktreeを消す前に、その終わりを待つ。subprocess.runは例外で子をSIGKILLし、後片付けを飛ばすので使わない
        for number in STOP_SIGNALS:
            signal.signal(number, signal.SIG_IGN)
        process.wait()
        raise
    if status != 0:
        raise SystemExit(f'error: 時間を記録するためのmake testが落ちました（{cwd}）')


def ensure_base_record(commit):
    tree = find_record(commit)
    if tree is not None:
        return tree
    print(f'{commit[:12]} のテストの時間の記録がないので、その中身でmake testを走らせます')
    path = common_dir() / 'scia-test-timing-base'
    toplevel = Path(git('rev-parse', '--show-toplevel').stdout.strip())
    remove_worktree(path)
    git('worktree', 'add', '--detach', '-q', str(path), commit)
    try:
        # 手元のビルドと同じ署名とコンパイルキャッシュで走らせる。worktreeの決まりどおり、元にあるものだけをコピーする
        for name in ['Local.xcconfig', 'CacheLocal.xcconfig']:
            source = toplevel / 'Config' / name
            if source.exists():
                shutil.copyfile(source, path / 'Config' / name)
        run_test(path)
    finally:
        remove_worktree(path)
    return require_record(commit)


def ensure_record_here(commit):
    tree = find_record(commit)
    if tree is not None:
        return tree
    print(f'{commit[:12]} のテストの時間の記録がないので、make testを走らせます')
    run_test(None)
    return require_record(commit)


def require_record(commit):
    tree = find_record(commit)
    if tree is None:
        raise SystemExit(f'error: make testが通ったのに {commit[:12]} の時間の記録がありません')
    return tree


def remove_worktree(path):
    if path.exists():
        git('worktree', 'remove', '--force', str(path), check=False)
        shutil.rmtree(path, ignore_errors=True)
    git('worktree', 'prune')


def gate(base, commit):
    base_commit = git('rev-parse', base).stdout.strip()
    commit = git('rev-parse', commit).stdout.strip()
    # この仕組みが入る前のcommitは、make testが時間を記録しないので、走らせても比べる元を作れない。この仕組みをmainへ入れる1回だけ起きる
    if git('cat-file', '-e', f'{base_commit}:Tools/test-timing.py', check=False).returncode != 0:
        print(f'{TARGET}（{base_commit[:12]}）にはテストの時間を記録する仕組みがないので、比べません')
        return 0
    base_tree = ensure_base_record(base_commit)
    tree = ensure_record_here(commit)
    if compare(base_tree, tree, f'{TARGET}（{base_commit[:12]}）'):
        return SLOW
    return 0


STOP_SIGNALS = [signal.SIGTERM, signal.SIGINT, signal.SIGHUP]


def main(arguments):
    for number in STOP_SIGNALS:
        signal.signal(number, on_signal)
    try:
        return run(arguments)
    except Stopped as stopped:
        return 128 + stopped.number


def run(arguments):
    match arguments:
        case ['record', tree, *results] if results:
            record(tree, results)
        case ['import', tree]:
            import_record(tree, sys.stdin.read())
        case ['warn']:
            warn()
        case ['gate', base, commit]:
            return gate(base, commit)
        case _:
            print(__doc__, file=sys.stderr)
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
